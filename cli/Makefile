# Build and install the chippy CLI.
#
#   make build                        build ./bin/chippy
#   make install                      install chippy into BINDIR (on your PATH)
#   make install CLIENT_ID=<id>       bake in the OAuth client ID (no CHIPPY_CLIENT_ID needed)
#   make install BINDIR=~/.local/bin  install somewhere else
#   make uninstall | test | clean

BINARY    := chippy
BUILD_DIR := bin
GOBIN     := $(shell go env GOBIN)
# Go's own bin directory: $GOBIN, else $GOPATH/bin (usually ~/go/bin).
BINDIR    ?= $(if $(GOBIN),$(GOBIN),$(shell go env GOPATH)/bin)
CLIENT_ID ?= $(CHIPPY_CLIENT_ID)

LDFLAGS := -s -w
ifneq ($(strip $(CLIENT_ID)),)
LDFLAGS += -X main.builtInClientID=$(CLIENT_ID)
endif

.PHONY: all build install uninstall test clean

all: build

build:
	go build -trimpath -ldflags "$(LDFLAGS)" -o $(BUILD_DIR)/$(BINARY) .
	@echo "Built $(BUILD_DIR)/$(BINARY)"

install: build
	@mkdir -p "$(BINDIR)"
	install -m 0755 $(BUILD_DIR)/$(BINARY) "$(BINDIR)/$(BINARY)"
	@echo "Installed $(BINDIR)/$(BINARY)"
	@case ":$$PATH:" in *":$(BINDIR):"*|*":$(BINDIR)/:"*) ;; \
		*) echo "Note: $(BINDIR) is not on your PATH. Add it with: export PATH=\"$(BINDIR):\$$PATH\"" ;; esac

uninstall:
	rm -f "$(BINDIR)/$(BINARY)"
	@echo "Removed $(BINDIR)/$(BINARY)"

test:
	go test -race ./...

clean:
	rm -rf $(BUILD_DIR)
