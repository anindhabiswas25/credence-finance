# Credence Finance: root Makefile.
# Each team owns its own fragment in mk/ (contracts.mk = blockchain, backend.mk = backend, …).
# Do not add targets here; add them to your fragment.
.PHONY: help
help:
	@grep -hE '^[a-zA-Z0-9_-]+:.*## ' $(MAKEFILE_LIST) | sort | awk 'BEGIN{FS=":.*## "}{printf "  %-24s %s\n", $$1, $$2}'

-include mk/*.mk
