BINARY   := questmaster
INSTALL  := $(HOME)/.local/bin/$(BINARY)

.PHONY: install clean

install:
	@mkdir -p $(dir $(INSTALL))
	GOPRIVATE='github.com/alexivison/*' GOSUMDB=off GOPROXY=direct GOBIN=$(dir $(INSTALL)) go install github.com/alexivison/questmaster@latest
	@echo "installed $(INSTALL)"

clean:
	rm -f $(INSTALL)
