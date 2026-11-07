CC ?= gcc
CFLAGS ?= -O2
LIBDIR ?= /usr/lib64
all: libgreet.so.1.0
libgreet.so.1.0: greet.c greet.h
	$(CC) $(CFLAGS) $(LDFLAGS) -fPIC -shared -Wl,-soname,libgreet.so.1 -o $@ greet.c
install: all
	install -D -m 0755 libgreet.so.1.0 $(DESTDIR)$(LIBDIR)/libgreet.so.1.0
	ln -s libgreet.so.1.0 $(DESTDIR)$(LIBDIR)/libgreet.so.1
	ln -s libgreet.so.1 $(DESTDIR)$(LIBDIR)/libgreet.so
	install -D -m 0644 greet.h $(DESTDIR)/usr/include/greet.h
