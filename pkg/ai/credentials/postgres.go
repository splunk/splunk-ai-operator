// Package credentials validates credential inputs without including their values
// in errors. It is shared by admission and reconciliation so webhook bypass does
// not turn an unsupported plaintext setting into a generated workload value.
package credentials

import (
	"fmt"
	"net/url"
	"strconv"
	"strings"
	"unicode/utf8"

	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/util/validation/field"
)

var postgresKeys = []string{"DATABASE_URL", "PG_HOST", "PG_PORT", "PG_USER", "PG_PASSWORD", "PG_DBNAME"}

// Importing the whole Secret also imports libpq's alternate connection inputs.
// Keep these out of both configuration paths so they cannot redirect a client
// after the six selected contract keys have been validated.
var postgresConnectionAliases = []string{
	"PGHOST", "PGHOSTADDR", "PGPORT", "PGUSER", "PGPASSWORD", "PGDATABASE",
	"PGPASSFILE", "PGSERVICE", "PGSERVICEFILE",
}

// ValidationError contains only a fixed field name and explanation, never an
// input value or an error returned by a URI parser.
type ValidationError struct{ message string }

func (e *ValidationError) Error() string { return e.message }

// ValidatePostgresEnvironment forbids connection overrides, including empty
// literals and libpq aliases. Optional non-credential settings such as PGSSLMODE
// and PG_SSLMODE remain supported. The Secret is the single connection source.
func ValidatePostgresEnvironment(values map[string]string, path *field.Path) field.ErrorList {
	var errs field.ErrorList
	for _, name := range append(append([]string{}, postgresKeys...), postgresConnectionAliases...) {
		if _, exists := values[name]; exists {
			errs = append(errs, field.Forbidden(path.Key(name), "supply PostgreSQL connection settings through checkpointDbSecretRef"))
		}
	}
	for _, name := range []string{"PGSSLMODE", "PG_SSLMODE"} {
		if !validSSLMode(values[name]) {
			errs = append(errs, field.Forbidden(path.Key(name), "must use a supported PostgreSQL SSL mode"))
		}
	}
	return errs
}

func validSSLMode(mode string) bool {
	switch mode {
	case "", "disable", "allow", "prefer", "require", "verify-ca", "verify-full":
		return true
	default:
		return false
	}
}

// ValidatePostgresSecret checks the selected password-based connection contract
// locally. It makes no network calls and never tests or changes a database user.
func ValidatePostgresSecret(secret *corev1.Secret) error {
	fail := func(message string) error { return &ValidationError{message: "checkpoint Secret " + message} }
	if secret == nil || secret.Type != corev1.SecretTypeOpaque {
		return fail("must have type Opaque")
	}
	for _, key := range postgresConnectionAliases {
		if _, exists := secret.Data[key]; exists {
			return fail(key + " must be omitted; use the six PostgreSQL contract keys")
		}
	}
	for _, key := range postgresKeys {
		value := string(secret.Data[key])
		if strings.TrimSpace(value) == "" || !utf8.ValidString(value) || strings.ContainsAny(value, "\x00\r\n") {
			return fail(key + " must be a nonempty single-line UTF-8 value")
		}
	}
	for _, key := range []string{"PGSSLMODE", "PG_SSLMODE"} {
		if !validSSLMode(string(secret.Data[key])) {
			return fail(key + " must use a supported PostgreSQL SSL mode")
		}
	}
	// libpq expands a -d value containing '=' or a URI prefix as connection
	// settings, which would override the separately validated host and user.
	database := string(secret.Data["PG_DBNAME"])
	if strings.Contains(database, "=") || strings.HasPrefix(database, "postgres://") || strings.HasPrefix(database, "postgresql://") {
		return fail("PG_DBNAME must be a literal database name, not connection settings")
	}
	u, err := url.Parse(string(secret.Data["DATABASE_URL"]))
	if err != nil || u == nil || (u.Scheme != "postgres" && u.Scheme != "postgresql") || u.Hostname() == "" || u.User == nil || u.Fragment != "" || u.Opaque != "" {
		return fail("DATABASE_URL must be a PostgreSQL URI with host, user, password and database")
	}
	password, present := u.User.Password()
	if !present || password == "" || u.User.Username() == "" || !strings.HasPrefix(u.Path, "/") || len(u.Path) <= 1 {
		return fail("DATABASE_URL must include user, password and database")
	}
	query, err := url.ParseQuery(u.RawQuery)
	if err != nil {
		return fail("DATABASE_URL has invalid connection options")
	}
	// libpq query options can override URI identity. Refuse ambiguous connections
	// instead of comparing one identity while the database client uses another.
	for key, values := range query {
		if len(values) != 1 {
			return fail("DATABASE_URL must not repeat connection options")
		}
		switch strings.ToLower(key) {
		case "host", "hostaddr", "port", "user", "password", "dbname", "service", "servicefile", "passfile":
			return fail("DATABASE_URL must not override connection identity in query options")
		}
	}
	if !validSSLMode(query.Get("sslmode")) {
		return fail("DATABASE_URL must use a supported PostgreSQL SSL mode")
	}
	port := u.Port()
	if port == "" {
		port = "5432"
	}
	uriPort, err := strconv.Atoi(port)
	if err != nil || uriPort < 1 || uriPort > 65535 {
		return fail("DATABASE_URL port must be between 1 and 65535")
	}
	structuredPort, err := strconv.Atoi(string(secret.Data["PG_PORT"]))
	if err != nil || structuredPort < 1 || structuredPort > 65535 {
		return fail("PG_PORT must be between 1 and 65535")
	}
	if strings.ContainsAny(u.Hostname(), ", \t") || strings.Contains(u.Hostname(), "/") {
		return fail("DATABASE_URL must identify one TCP host")
	}
	for _, check := range []struct {
		key string
		ok  bool
	}{
		{"PG_HOST", strings.EqualFold(u.Hostname(), string(secret.Data["PG_HOST"]))},
		{"PG_PORT", uriPort == structuredPort},
		{"PG_USER", u.User.Username() == string(secret.Data["PG_USER"])},
		{"PG_PASSWORD", password == string(secret.Data["PG_PASSWORD"])},
		{"PG_DBNAME", strings.TrimPrefix(u.Path, "/") == string(secret.Data["PG_DBNAME"])},
	} {
		if !check.ok {
			return fail(fmt.Sprintf("%s must agree with DATABASE_URL", check.key))
		}
	}
	return nil
}
