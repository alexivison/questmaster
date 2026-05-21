BINARY   := party-cli
INSTALL  := $(HOME)/.local/bin/$(BINARY)

.PHONY: install clean

install:
	@mkdir -p $(dir $(INSTALL))
	go build -buildvcs=false -o $(INSTALL) .
	@echo "installed $(INSTALL)"

clean:
	rm -f $(INSTALL)
