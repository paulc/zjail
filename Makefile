
SRC := Makefile src/zjail.sh src/log.sh src/util.sh src/config.sh src/setup.sh src/base.sh src/instance.sh src/create.sh

bin/zjail: $(SRC)
	sed -e '/INSERT: log.sh/r src/log.sh' \
		-e '/INSERT: util.sh/r src/util.sh' \
		-e '/INSERT: config.sh/r src/config.sh' \
		-e '/INSERT: setup.sh/r src/setup.sh' \
		-e '/INSERT: base.sh/r src/base.sh' \
		-e '/INSERT: instance.sh/r src/instance.sh' \
		-e '/INSERT: create.sh/r src/create.sh' \
		-e 's/^MERGED=""/MERGED=1/' \
		src/zjail.sh > bin/zjail
	chmod 755 bin/zjail

.PHONY: clean
clean:
	rm -f bin/zjail

.PHONY: test
test: bin/zjail
	./test/run.sh
