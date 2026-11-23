package credentials

import (
	"net/url"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/util/validation/field"
)

const testPassword = "checkpoint-canary-P@ss:word/2026"

func validSecret() *corev1.Secret {
	u := url.URL{Scheme: "postgresql", Host: "postgres.example:5432", Path: "/checkpoints", User: url.UserPassword("checkpoint-user", testPassword)}
	return &corev1.Secret{Type: corev1.SecretTypeOpaque, Data: map[string][]byte{
		"DATABASE_URL": []byte(u.String()), "PG_HOST": []byte("postgres.example"), "PG_PORT": []byte("5432"),
		"PG_USER": []byte("checkpoint-user"), "PG_PASSWORD": []byte(testPassword), "PG_DBNAME": []byte("checkpoints"),
	}}
}

func TestPostgresSecretContract(t *testing.T) {
	require.NoError(t, ValidatePostgresSecret(validSecret()))
	for _, key := range postgresKeys {
		t.Run("missing "+key, func(t *testing.T) {
			s := validSecret()
			delete(s.Data, key)
			err := ValidatePostgresSecret(s)
			require.ErrorContains(t, err, key)
			assert.NotContains(t, err.Error(), testPassword)
		})
		t.Run("empty "+key, func(t *testing.T) {
			s := validSecret()
			s.Data[key] = []byte(" \t")
			require.Error(t, ValidatePostgresSecret(s))
		})
	}
	for _, key := range []string{"PG_HOST", "PG_PORT", "PG_USER", "PG_PASSWORD", "PG_DBNAME"} {
		t.Run("conflicting "+key, func(t *testing.T) {
			s := validSecret()
			value := "conflicting-canary"
			if key == "PG_PORT" {
				value = "5440"
			}
			s.Data[key] = []byte(value)
			err := ValidatePostgresSecret(s)
			require.ErrorContains(t, err, key)
			assert.NotContains(t, err.Error(), value)
			assert.NotContains(t, err.Error(), testPassword)
		})
	}
	t.Run("Opaque type required", func(t *testing.T) {
		s := validSecret()
		s.Type = corev1.SecretTypeTLS
		require.ErrorContains(t, ValidatePostgresSecret(s), "Opaque")
	})
	for _, raw := range []string{
		"postgresql://user:bad%escape@host/db", "postgresql://user:canary@host:0/db",
		"postgresql://user:canary@host:65536/db", "postgresql://user:canary@host:port/db",
		"postgresql://user@host/db", "postgresql://user:canary@host/", "http://user:canary@host/db",
		"postgresql://user:canary@a,b/db", "postgresql://user:canary@host/db#fragment",
		"postgresql://user:canary@host/db?host=other", "postgresql://user:canary@host/db?password=other",
		"postgresql://user:canary@host/db?sslmode=disable&sslmode=require", "postgresql://user:canary@host/db?sslmode=%xx",
	} {
		s := validSecret()
		s.Data["DATABASE_URL"] = []byte(raw)
		err := ValidatePostgresSecret(s)
		require.Error(t, err)
		assert.NotContains(t, err.Error(), raw)
		assert.NotContains(t, err.Error(), "canary")
	}
	for _, port := range []string{"0", "65536", "5432oops"} {
		s := validSecret()
		s.Data["PG_PORT"] = []byte(port)
		require.ErrorContains(t, ValidatePostgresSecret(s), "PG_PORT")
	}
	// URI userinfo and paths are compared after decoding, including IPv6 hosts,
	// while an omitted port and a padded structured port mean the same number.
	s := validSecret()
	u := url.URL{Scheme: "postgres", Host: "[::1]", Path: "/check/points", User: url.UserPassword("user@example", testPassword)}
	s.Data["DATABASE_URL"] = []byte(u.String())
	s.Data["PG_HOST"], s.Data["PG_PORT"] = []byte("::1"), []byte("05432")
	s.Data["PG_USER"], s.Data["PG_DBNAME"] = []byte("user@example"), []byte("check/points")
	require.NoError(t, ValidatePostgresSecret(s))
}

func TestPostgresEnvironmentRejectsLiteralsWithoutEchoingValues(t *testing.T) {
	for _, name := range []string{"DATABASE_URL", "PG_PASSWORD", "PG_HOST", "PGPASSWORD", "PGPASSFILE", "PGSERVICE"} {
		for _, value := range []string{testPassword, ""} {
			errs := ValidatePostgresEnvironment(map[string]string{name: value}, field.NewPath("spec", "features").Index(0).Child("env"))
			require.Len(t, errs, 1)
			assert.Contains(t, errs.ToAggregate().Error(), name)
			assert.NotContains(t, errs.ToAggregate().Error(), testPassword)
		}
	}
	assert.Empty(t, ValidatePostgresEnvironment(map[string]string{"PG_SSLMODE": "require", "PGSSLMODE": "verify-full", "LOG_LEVEL": "info"}, field.NewPath("env")))
	for _, key := range []string{"PG_SSLMODE", "PGSSLMODE"} {
		errs := ValidatePostgresEnvironment(map[string]string{key: testPassword}, field.NewPath("env"))
		require.NotEmpty(t, errs)
		assert.NotContains(t, errs.ToAggregate().Error(), testPassword)
		s := validSecret()
		s.Data[key] = []byte(testPassword)
		err := ValidatePostgresSecret(s)
		require.Error(t, err)
		assert.NotContains(t, err.Error(), testPassword)
	}
	assert.NotContains(t, strings.Join(postgresKeys, ","), testPassword)
}

func TestPostgresSecretRejectsAlternateConnectionSources(t *testing.T) {
	for _, key := range postgresConnectionAliases {
		t.Run(key, func(t *testing.T) {
			s := validSecret()
			s.Data[key] = []byte("connection-override-canary")
			err := ValidatePostgresSecret(s)
			require.ErrorContains(t, err, key)
			assert.NotContains(t, err.Error(), "connection-override-canary")
		})
	}
	for _, database := range []string{"host=other dbname=checkpoints", "postgres://other/db", "postgresql://other/db"} {
		s := validSecret()
		u, err := url.Parse(string(s.Data["DATABASE_URL"]))
		require.NoError(t, err)
		u.Path = "/" + database
		s.Data["DATABASE_URL"], s.Data["PG_DBNAME"] = []byte(u.String()), []byte(database)
		err = ValidatePostgresSecret(s)
		require.ErrorContains(t, err, "PG_DBNAME")
		assert.NotContains(t, err.Error(), database)
	}
}
