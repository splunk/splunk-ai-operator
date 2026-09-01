# Contributing to Splunk AI Operator

Thank you for your interest in contributing to the Splunk AI Operator! This document provides guidelines and instructions for contributing.

## Table of Contents

- [Code of Conduct](#code-of-conduct)
- [Getting Started](#getting-started)
- [How to Contribute](#how-to-contribute)
- [Development Setup](#development-setup)
- [Pull Request Process](#pull-request-process)
- [Coding Standards](#coding-standards)
- [Testing](#testing)
- [Documentation](#documentation)
- [Community](#community)

## Code of Conduct

This project adheres to a [Code of Conduct](CODE_OF_CONDUCT.md). By participating, you are expected to uphold this code. Please report unacceptable behavior to splunkai@cisco.com.

## Getting Started

1. **Fork the repository** on GitHub
2. **Clone your fork** locally:
   ```bash
   git clone https://github.com/YOUR_USERNAME/splunk-ai-operator.git
   cd splunk-ai-operator
   ```
3. **Add upstream remote**:
   ```bash
   git remote add upstream https://github.com/splunk/splunk-ai-operator.git
   ```
4. **Create a branch** for your changes:
   ```bash
   git checkout -b feature/my-feature
   ```

## How to Contribute

### Reporting Bugs

Before creating bug reports, please check existing issues to avoid duplicates. When creating a bug report, include:

- **Clear title and description**
- **Steps to reproduce** the issue
- **Expected vs. actual behavior**
- **Environment details** (K8s version, operator version, cloud provider)
- **Logs and error messages**
- **Screenshots** if applicable

Use the [bug report template](.github/ISSUE_TEMPLATE/bug_report.md) when creating issues.

### Suggesting Enhancements

Enhancement suggestions are tracked as GitHub issues. When creating an enhancement suggestion:

- **Use a clear and descriptive title**
- **Provide a detailed description** of the proposed functionality
- **Explain why this enhancement would be useful**
- **List any similar features** in other projects

Use the [feature request template](.github/ISSUE_TEMPLATE/feature_request.md) when creating suggestions.

### Your First Code Contribution

Unsure where to begin? Look for issues tagged with:

- `good first issue` - Good for newcomers
- `help wanted` - Issues that need assistance
- `documentation` - Documentation improvements

### Pull Requests

1. **Ensure your PR addresses an existing issue** (or create one first)
2. **Follow the coding standards** outlined below
3. **Include tests** for new functionality
4. **Update documentation** as needed
5. **Keep PRs focused** - one feature or fix per PR
6. **Write clear commit messages** following conventional commits

## Development Setup

### Prerequisites

- **Go**: 1.21 or higher
- **Docker**: For building container images
- **kubectl**: Kubernetes CLI tool
- **kind** or **minikube**: For local testing
- **make**: Build automation

### Install Dependencies

```bash
# Install Go dependencies
go mod download

# Install development tools
make install-dev-tools
```

### Local Development

```bash
# Run unit tests
make test

# Run linters
make lint

# Build the operator binary
make build

# Build container image
make docker-build

# Run locally (outside cluster)
make run
```

### Running Tests

```bash
# Unit tests
make test

# Integration tests
make test-integration

# E2E tests (requires cluster)
make test-e2e

# Test coverage
make coverage
```

## Pull Request Process

### Before Submitting

1. **Sync with upstream**:
   ```bash
   git fetch upstream
   git rebase upstream/main
   ```

2. **Run all tests**:
   ```bash
   make test
   make lint
   ```

3. **Update documentation**:
   - Update README.md if adding features
   - Add/update inline code comments
   - Update API documentation

4. **Update CHANGELOG.md** with your changes

### Commit Message Format

Follow [Conventional Commits](https://www.conventionalcommits.org/):

```
<type>(<scope>): <subject>

<body>

<footer>
```

**Types**:
- `feat`: New feature
- `fix`: Bug fix
- `docs`: Documentation only
- `style`: Code style changes (formatting, no logic change)
- `refactor`: Code refactoring
- `perf`: Performance improvement
- `test`: Adding or updating tests
- `chore`: Maintenance tasks

**Examples**:
```
feat(aiplatform): add support for custom storage classes

fix(webhook): resolve validation error for empty namespace

docs(readme): update installation instructions for EKS
```

### PR Title Format

Use the same format as commit messages:

```
feat(aiplatform): add support for custom accelerator types
```

### PR Description

Include in your PR description:

- **What**: Summary of changes
- **Why**: Motivation and context
- **How**: Technical approach
- **Testing**: How you tested the changes
- **Screenshots**: If UI changes
- **Related Issues**: Closes #123, Fixes #456

### Review Process

1. **Automated checks must pass**:
   - Unit tests
   - Linting
   - Helm chart validation
   - Vulnerability scan

2. **Code review** by at least one maintainer

3. **Approval** required before merging

4. **Maintainer will merge** once approved

### After Merge

- Delete your branch
- Update your local repository:
  ```bash
  git checkout main
  git pull upstream main
  ```

## Coding Standards

### Go Code

- Follow [Effective Go](https://golang.org/doc/effective_go.html)
- Use `gofmt` for formatting
- Run `golangci-lint` before committing
- Write meaningful variable and function names
- Add comments for exported functions
- Keep functions small and focused

### Code Structure

```go
// Good: Clear, documented, single responsibility
// ReconcileAIPlatform reconciles the AIPlatform resource
// and returns the reconciliation result and any error encountered.
func (r *AIPlatformReconciler) ReconcileAIPlatform(ctx context.Context, platform *aiv1.AIPlatform) (ctrl.Result, error) {
    // Implementation
}

// Bad: Unclear, undocumented, multiple responsibilities
func (r *AIPlatformReconciler) Do(p *aiv1.AIPlatform) (ctrl.Result, error) {
    // Complex logic doing multiple things
}
```

### Error Handling

```go
// Good: Wrap errors with context
if err != nil {
    return ctrl.Result{}, fmt.Errorf("failed to create RayService: %w", err)
}

// Bad: Return bare errors
if err != nil {
    return ctrl.Result{}, err
}
```

### Logging

Use structured logging:

```go
// Good
log.Info("Reconciling AIPlatform",
    "namespace", platform.Namespace,
    "name", platform.Name,
    "phase", platform.Status.Phase)

// Bad
log.Info(fmt.Sprintf("Reconciling %s/%s in phase %s",
    platform.Namespace, platform.Name, platform.Status.Phase))
```

### Kubernetes Resources

- Use `ctrl.SetControllerReference` for owned resources
- Add labels and annotations consistently
- Use finalizers for cleanup
- Implement proper status conditions

## Testing

### Unit Tests

- Test files should end in `_test.go`
- Use table-driven tests
- Mock external dependencies
- Aim for >80% coverage

```go
func TestAIPlatformReconcile(t *testing.T) {
    tests := []struct {
        name    string
        platform *aiv1.AIPlatform
        want    ctrl.Result
        wantErr bool
    }{
        {
            name: "creates RayService successfully",
            platform: &aiv1.AIPlatform{...},
            want: ctrl.Result{},
            wantErr: false,
        },
        // More test cases
    }

    for _, tt := range tests {
        t.Run(tt.name, func(t *testing.T) {
            // Test implementation
        })
    }
}
```

### Integration Tests

- Test real Kubernetes interactions
- Use `envtest` for controller testing
- Clean up resources after tests

### E2E Tests

- Test complete workflows
- Use real clusters (kind/minikube)
- Test failure scenarios

## Documentation

### Code Documentation

- Document all exported types, functions, and constants
- Use complete sentences
- Include examples where helpful

### User Documentation

Update relevant documentation:

- `README.md` - Project overview
- `docs/` - Detailed guides
- `docs/ai_tier_deployment/` - AI-tier deployment guides
- `tools/ai_tier_cluster_setup/` - Installer scripts, configuration, and tests
- Helm chart README files

### API Documentation

- CRD fields must have `+kubebuilder:` markers
- Include validation rules
- Add examples in CRD comments

## Community

### Communication Channels

- **GitHub Issues**: Bug reports and feature requests
- **GitHub Discussions**: Questions and general discussion
- **Pull Requests**: Code review and collaboration
- **Email**: splunkai@cisco.com for sensitive topics

### Getting Help

- Check existing [documentation](README.md)
- Search [existing issues](https://github.com/splunk/splunk-ai-operator/issues)
- Ask in [GitHub Discussions](https://github.com/splunk/splunk-ai-operator/discussions)

### Recognition

Contributors are recognized in:

- Release notes
- CHANGELOG.md
- Project README (top contributors)

## License

By contributing, you agree that your contributions will be licensed under the same license as the project (see [LICENSE](LICENSE) file).

## Questions?

Don't hesitate to ask! We're here to help:

- Open a [discussion](https://github.com/splunk/splunk-ai-operator/discussions)
- Email us at splunkai@cisco.com
- Comment on an existing issue

Thank you for contributing! 🎉
