
SRC := Makefile src/zjail.sh src/log.sh src/util.sh src/config.sh src/setup.sh src/base.sh src/instance.sh src/create.sh

bin/zjail: $(SRC)
	sed -e '/log.sh/r src/log.sh' -e '/log.sh/d' \
		-e '/util.sh/r src/util.sh' -e '/util.sh/d' \
		-e '/config.sh/r src/config.sh' -e '/config.sh/d' \
		-e '/setup.sh/r src/setup.sh' -e '/setup.sh/d' \
		-e '/base.sh/r src/base.sh' -e '/base.sh/d' \
		-e '/instance.sh/r src/instance.sh' -e '/instance.sh/d' \
		-e '/create.sh/r src/create.sh' -e '/create.sh/d' \
		-e 's/MERGE_MARKER/MERGED_FILE - DO NOT EDIT/' \
		src/zjail.sh > bin/zjail
	chmod 755 bin/zjail

clean:
	rm -f bin/zjail
