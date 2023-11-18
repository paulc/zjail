
SRC := Makefile \
	   src/zjail.sh \
	   src/log.sh \
	   src/util.sh \
	   src/config.sh \
	   src/setup.sh \
	   src/base.sh \
	   src/instance.sh \
	   src/create_instance.sh \
	   src/build.sh

# Note - tmp files will always be generated so need to cleanup
USAGE != mktemp
CMDS != mktemp

bin/zjail: $(SRC)
	# Generate USAGE
	grep -h '^[a-z][a-zA-Z_].*(' src/* | \
		sed -e 's/(.*#//' -e 's/(.*$$//' -e 's/^/    /' | \
		( echo 'USAGE="'; sort; echo '"' ) > $(USAGE)
	# Generate CMDS
	grep -h '^[a-z][a-zA-Z_].*(' src/* | \
		sed -e 's/\(.*\)(.*$$/\1)  \1 "$$@";;/' -e 's/^/    /' | \
		( printf 'case "$${cmd}" in\n' ; sort; printf '    *) echo "\nUsage: $$0 <cmd> [args..]\n$${USAGE}";exit 1;;\nesac\n' ) > $(CMDS)
	# Genarate merged cmd
	sed -e '/INSERT: log.sh/r src/log.sh' \
		-e '/INSERT: util.sh/r src/util.sh' \
		-e '/INSERT: config.sh/r src/config.sh' \
		-e '/INSERT: setup.sh/r src/setup.sh' \
		-e '/INSERT: base.sh/r src/base.sh' \
		-e '/INSERT: instance.sh/r src/instance.sh' \
		-e '/INSERT: create_instance.sh/r src/create_instance.sh' \
		-e '/INSERT: build.sh/r src/build.sh' \
		-e '/INSERT: USAGE/r $(USAGE)' \
		-e '/INSERT: CMDS/r $(CMDS)' \
		-e 's/^MERGED=.*/MERGED=1/' \
		src/zjail.sh > bin/zjail
	# Mark as executable
	chmod 755 bin/zjail

src/build.sh: src/create_instance.sh
	# Generate build.sh from create_instance.sh
	sed -e '/START_CREATE/,/END_CREATE/s/^/#/' -e '/START_BUILD/,/END_BUILD/s/^#//' src/create_instance.sh > src/build.sh

.END: cleanup
cleanup:
	# Cleanup tmp files
	rm -f $(USAGE) $(CMDS)

.PHONY: clean
clean:
	rm -f bin/zjail $(USAGE) $(CMDS)

.PHONY: test
test: bin/zjail /usr/local/bin/shunit2
	./test/shunit.sh 2>/dev/null

.PHONY: shellcheck
shellcheck: bin/zjail /usr/local/bin/shellcheck
	/usr/local/bin/shellcheck -e SC3043,SC2124,SC2214,SC3040,SC1091 bin/zjail
