Name:           myorg-greeter
Version:        1.0
Release:        1%{?dist}
Summary:        Tiny greeting command for the packaging lab
License:        MIT
Source0:        greeter-%{version}.tar.gz
BuildRequires:  gcc make myorg-libgreet-devel

%description
Prints a greeting obtained from libgreet.

%prep
%autosetup -n greeter-%{version}

%build
%make_build CFLAGS="%{optflags}" LDFLAGS="%{build_ldflags}"

%install
%make_install

%files
%{_bindir}/greeter

%changelog
* Fri Nov 06 2026 Lab Author <lab@example.com> - 1.0-1
- Initial package
