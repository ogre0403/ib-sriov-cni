# Package related
BINARY_NAME=infiniband
PACKAGE=ib-sriov-cni
ORG_PATH=github.com/Mellanox
REPO_PATH=$(ORG_PATH)/$(PACKAGE)
GOPATH=$(CURDIR)/.gopath
GOBIN =$(CURDIR)/bin
BUILDDIR=$(CURDIR)/build
BASE=$(GOPATH)/src/$(REPO_PATH)
GOFILES=$(shell find . -name *.go | grep -vE "(\/vendor\/)|(_test.go)")
PKGS=$(or $(PKG),$(shell cd $(BASE) && env GOPATH=$(GOPATH) $(GO) list ./... | grep -v "^$(PACKAGE)/vendor/"))
TESTPKGS = $(shell env GOPATH=$(GOPATH) $(GO) list -f '{{ if or .TestGoFiles .XTestGoFiles }}{{ .ImportPath }}{{ end }}' $(PKGS))

export GOPATH
export GOBIN

# Docker
IMAGE_BUILDER?=@docker
IMAGEDIR=$(BASE)/images
DOCKERFILE?=$(CURDIR)/Dockerfile
TAG?=mellanox/ib-sriov-cni
IMAGE_BUILD_OPTS?=
# Accept proxy settings for docker
# To pass proxy for Docker invoke it as 'make image HTTP_POXY=http://192.168.0.1:8080'
DOCKERARGS=
ifdef HTTP_PROXY
	DOCKERARGS += --build-arg http_proxy=$(HTTP_PROXY)
endif
ifdef HTTPS_PROXY
	DOCKERARGS += --build-arg https_proxy=$(HTTPS_PROXY)
endif
IMAGE_BUILD_OPTS += $(DOCKERARGS)

# Go tools
GO      = go
GOFMT   = gofmt
GOLINT = $(GOBIN)/golint
TIMEOUT = 15
V = 0
Q = $(if $(filter 1,$V),,@)

.PHONY: all
all: fmt lint build

$(BASE): ; $(info  setting GOPATH...)
	@mkdir -p $(dir $@)
	@ln -sf $(CURDIR) $@

$(GOBIN):
	@mkdir -p $@

$(BUILDDIR): | $(BASE) ; $(info Creating build directory...)
	@cd $(BASE) && mkdir -p $@

build: $(BUILDDIR)/$(BINARY_NAME) ; $(info Building $(BINARY_NAME)...) ## Build executable file
	$(info Done!)

$(BUILDDIR)/$(BINARY_NAME): $(GOFILES) | $(BUILDDIR)
	@cd $(BASE)/cmd/$(BINARY_NAME) && CGO_ENABLED=0 $(GO) build -o $(BUILDDIR)/$(BINARY_NAME) -tags no_openssl -v

# Tools

.PHONY: fmt
fmt: ; $(info  running gofmt...) @ ## Run gofmt on all source files
	@ret=0 && for d in $$($(GO) list -f '{{.Dir}}' ./... | grep -v /vendor/); do \
		$(GOFMT) -l -w $$d/*.go || ret=$$? ; \
	 done ; exit $$ret

$(GOLINT): | $(BASE) ; $(info  building golint...)
	$Q go get -u golang.org/x/lint/golint

GOCOVMERGE = $(GOBIN)/gocovmerge
$(GOBIN)/gocovmerge: | $(BASE) ; $(info  building gocovmerge...)
	$Q go get github.com/wadey/gocovmerge

GOCOV = $(GOBIN)/gocov
$(GOBIN)/gocov: | $(BASE) ; $(info  building gocov...)
	$Q go get github.com/axw/gocov/...

GOCOVXML = $(GOBIN)/gocov-xml
$(GOBIN)/gocov-xml: | $(BASE) ; $(info  building gocov-xml...)
	$Q go get github.com/AlekSi/gocov-xml

GO2XUNIT = $(GOBIN)/go2xunit
$(GOBIN)/go2xunit: | $(BASE) ; $(info  building go2xunit...)
	$Q go get github.com/tebeka/go2xunit

# Tests

.PHONY: lint
lint: | $(BASE) $(GOLINT) ; $(info  running golint...) @ ## Run golint
	$Q cd $(BASE) && ret=0 && for pkg in $(PKGS); do \
		test -z "$$($(GOLINT) $$pkg | tee /dev/stderr)" || ret=1 ; \
	 done ; exit $$ret

TEST_TARGETS := test-default test-bench test-short test-verbose test-race
.PHONY: $(TEST_TARGETS) test-xml check test tests
test-bench:   ARGS=-run=__absolutelynothing__ -bench=. ## Run benchmarks
test-short:   ARGS=-short        ## Run only short tests
test-verbose: ARGS=-v            ## Run tests in verbose mode with coverage reporting
test-race:    ARGS=-race         ## Run tests with race detector
$(TEST_TARGETS): NAME=$(MAKECMDGOALS:test-%=%)
$(TEST_TARGETS): test
check test tests: fmt lint | $(BASE) ; $(info  running $(NAME:%=% )tests...) @ ## Run tests
	$Q cd $(BASE) && $(GO) test -timeout $(TIMEOUT)s $(ARGS) $(TESTPKGS)

test-xml: fmt lint | $(BASE) $(GO2XUNIT) ; $(info  running $(NAME:%=% )tests...) @ ## Run tests with xUnit output
	$Q cd $(BASE) && 2>&1 $(GO) test -timeout 20s -v $(TESTPKGS) | tee test/tests.output
	$(GO2XUNIT) -fail -input test/tests.output -output test/tests.xml

COVERAGE_MODE = atomic
COVERAGE_PROFILE = $(COVERAGE_DIR)/profile.out
COVERAGE_XML = $(COVERAGE_DIR)/coverage.xml
COVERAGE_HTML = $(COVERAGE_DIR)/index.html
.PHONY: test-coverage test-coverage-tools
test-coverage-tools: | $(GOCOVMERGE) $(GOCOV) $(GOCOVXML)
test-coverage: COVERAGE_DIR := $(CURDIR)/test/coverage.$(shell date -u +"%Y-%m-%dT%H:%M:%SZ")
test-coverage: fmt lint test-coverage-tools | $(BASE) ; $(info  running coverage tests...) @ ## Run coverage tests
	$Q mkdir -p $(COVERAGE_DIR)/coverage
	$Q cd $(BASE) && for pkg in $(TESTPKGS); do \
		$(GO) test \
			-coverpkg=$$($(GO) list -f '{{ join .Deps "\n" }}' $$pkg | \
					grep '^$(PACKAGE)/' | grep -v '^$(PACKAGE)/vendor/' | \
					tr '\n' ',')$$pkg \
			-covermode=$(COVERAGE_MODE) \
			-coverprofile="$(COVERAGE_DIR)/coverage/`echo $$pkg | tr "/" "-"`.cover" $$pkg ;\
	 done
	$Q $(GOCOVMERGE) $(COVERAGE_DIR)/coverage/*.cover > $(COVERAGE_PROFILE)
	$Q $(GO) tool cover -html=$(COVERAGE_PROFILE) -o $(COVERAGE_HTML)
	$Q $(GOCOV) convert $(COVERAGE_PROFILE) | $(GOCOVXML) > $(COVERAGE_XML)

# Container image
.PHONY: image
image: | $(BASE) ; $(info Building Docker image...)  ## Build conatiner image
	$(IMAGE_BUILDER) build -t $(TAG) -f $(DOCKERFILE)  $(CURDIR) $(IMAGE_BUILD_OPTS)


# Misc

.PHONY: clean
clean: ; $(info  Cleaning...)	 ## Cleanup everything
	@rm -rf $(GOPATH)
	@rm -rf $(BUILDDIR)
	@rm -rf  test/tests.* test/coverage.*

.PHONY: help
help: ## Show this message
	@grep -E '^[ a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'