CC ?= gcc
CFLAGS ?= -O2
all: greeter
greeter: greeter.c
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ greeter.c -lgreet
install: all
	install -D -m 0755 greeter $(DESTDIR)/usr/bin/greeter
