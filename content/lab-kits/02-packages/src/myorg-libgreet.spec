Name:           myorg-libgreet
Version:        1.0
Release:        1%{?dist}
Summary:        Tiny greeting library for the packaging lab
License:        MIT
Source0:        libgreet-%{version}.tar.gz
BuildRequires:  gcc make

%description
A one-function shared library used to practice building and signing RPMs.

%package devel
Summary:        Headers and link symlink for myorg-libgreet
Requires:       %{name}%{?_isa} = %{version}-%{release}

%description devel
Development files for myorg-libgreet.

%prep
%autosetup -n libgreet-%{version}

%build
%make_build CFLAGS="%{optflags}" LDFLAGS="%{build_ldflags}"

%install
%make_install LIBDIR=%{_libdir}

%files
%{_libdir}/libgreet.so.1*

%files devel
%{_includedir}/greet.h
%{_libdir}/libgreet.so

%changelog
* Fri Nov 06 2026 Lab Author <lab@example.com> - 1.0-1
- Initial package
