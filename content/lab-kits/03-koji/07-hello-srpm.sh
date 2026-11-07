#!/bin/bash
# Run as normal user: build a tiny hello-world SRPM (no compiler needed, shell script)
set -euxo pipefail
mkdir -p ~/rpmbuild/{SPECS,SOURCES}
cat > ~/rpmbuild/SOURCES/hello.sh <<'S'
#!/bin/sh
echo "hello from a Koji-built package"
S
cat > ~/rpmbuild/SPECS/hello.spec <<'S'
Name:       hello
Version:    1.0
Release:    1%{?dist}
Summary:    Hello world for the Koji lab
License:    MIT
BuildArch:  noarch
Source0:    hello.sh

%description
Tiny shell-script package used to prove the Koji pipeline works.

%prep
%build
%install
install -D -m 0755 %{SOURCE0} %{buildroot}%{_bindir}/hello-koji

%files
%{_bindir}/hello-koji
S
rpmbuild -bs --define "dist .el10" ~/rpmbuild/SPECS/hello.spec
ls ~/rpmbuild/SRPMS
