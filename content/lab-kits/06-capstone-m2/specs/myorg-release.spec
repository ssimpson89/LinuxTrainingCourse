# myorg-release.spec: the smallest honest identity package set for a rebuild.
# One SRPM, three binary packages (same shape as the upstream release SRPM):
#   myorg-release   os-release, release files, macros.dist, system-release
#   myorg-repos     repo files and dnf vars
#   myorg-gpg-keys  the MyOrg public key and the seed's public key
# Deliberately NOT here: logos, secure boot certs, systemd presets, sysctl
# defaults, EULA. See README "Design decisions".

# The spec sets its own dist tag. It is built in a buildroot that still has
# the seed's macros.dist (dist = .el10), and a define in the spec itself wins (write percent signs as double percent in comments).
%define dist         .myorg
%define distro_name  MyOrg Lab Linux
%define major        10
%define minor        2
%define full_version %{major}.%{minor}
%define codename     Prototype

Name:           myorg-release
Version:        %{full_version}
Release:        1%{dist}
Summary:        %{distro_name} release files
License:        MIT
BuildArch:      noarch
Source0:        LICENSE
Source1:        RPM-GPG-KEY-myorg
Source2:        RPM-GPG-KEY-upstream-seed
Source3:        myorg.repo
Source4:        myorg-seed.repo

# Identity capabilities other packages ask for by name.
Provides:       system-release = %{version}-%{release}
Provides:       system-release(releasever) = %{major}
Provides:       system-release(releasever_major) = %{major}
Provides:       system-release(releasever_minor) = %{minor}
Provides:       base-module(platform:el%{major})
# EPEL and a few other third-party repos Require: redhat-release by name.
# This is a capability for compatibility, not a claim of origin.
Provides:       redhat-release = %{version}-%{release}
Requires:       myorg-repos(%{major})

%description
Release files for %{distro_name}: os-release, release strings, the dist tag
macros and the system-release capability. A rebuild of Rocky Linux sources
under a different name. Not affiliated with or endorsed by its seed.

%package -n myorg-repos
Summary:        %{distro_name} package repositories
Provides:       system-repos = %{version}-%{release}
Provides:       myorg-repos(%{major}) = %{full_version}
Requires:       myorg-release = %{version}-%{release}
Requires:       myorg-gpg-keys = %{version}-%{release}

%description -n myorg-repos
Repository definitions for the MyOrg repository and the upstream seed, and the
dnf variables that locate them.

%package -n myorg-gpg-keys
Summary:        %{distro_name} RPM GPG keys

%description -n myorg-gpg-keys
The MyOrg RPM signing public key, and the public key of the seed repository
(needed to verify the packages MyOrg did not rebuild).

%prep
echo nothing to unpack

%build
echo nothing to build

%install
install -d %{buildroot}%{_sysconfdir} %{buildroot}%{_prefix}/lib

# Release string, and the generic names tools look for.
echo "%{distro_name} release %{full_version} (%{codename})" > %{buildroot}%{_sysconfdir}/myorg-release
echo "Rebuilt from Rocky Linux %{full_version} sources" > %{buildroot}%{_sysconfdir}/myorg-release-upstream
ln -s myorg-release %{buildroot}%{_sysconfdir}/system-release
ln -s myorg-release %{buildroot}%{_sysconfdir}/redhat-release
echo "cpe:/o:myorg:myorg:%{major}" > %{buildroot}%{_sysconfdir}/system-release-cpe

# os-release lives in /usr/lib, /etc/os-release is a relative symlink to it.
cat > %{buildroot}%{_prefix}/lib/os-release <<EOT
NAME="%{distro_name}"
VERSION="%{full_version} (%{codename})"
ID="myorg"
ID_LIKE="rocky rhel centos fedora"
VERSION_ID="%{full_version}"
PLATFORM_ID="platform:el%{major}"
PRETTY_NAME="%{distro_name} %{full_version} (%{codename})"
ANSI_COLOR="0;34"
CPE_NAME="cpe:/o:myorg:myorg:%{major}"
HOME_URL="https://myorg.example/"
VENDOR_NAME="MyOrg"
BUG_REPORT_URL="https://myorg.example/bugs"
EOT
ln -s ../usr/lib/os-release %{buildroot}%{_sysconfdir}/os-release

# login banners; /etc/issue.d must exist because other packages (for
# example console-login-helper-messages-issuegen) Require it by path.
printf '\\S\nKernel \\r on \\m\n\n' > %{buildroot}%{_sysconfdir}/issue
cp %{buildroot}%{_sysconfdir}/issue %{buildroot}%{_sysconfdir}/issue.net
mkdir -p %{buildroot}%{_sysconfdir}/issue.d

# The dist tag. rpm reads every file in %{_rpmmacrodir} at startup, so any
# buildroot that has this package installed builds with .myorg.
mkdir -p %{buildroot}%{_rpmmacrodir}
cat > %{buildroot}%{_rpmmacrodir}/macros.dist <<'EOT'
%%myorg %{major}
%%myorg_ver %{major}
%%rhel %{major}
%%el%{major} 1
%%distcore .myorg
%%dist %%{!?distprefix0:%%{?distprefix}}%%{expand:%%{lua:for i=0,9999 do print("%%{?distprefix" .. i .."}") end}}%%{distcore}%%{?distsuffix}
%%dist_vendor MyOrg
%%dist_name %{distro_name}
%%dist_home_url https://myorg.example/
%%dist_bug_report_url https://myorg.example/bugs
EOT

# docs
install -d %{buildroot}%{_datadir}/myorg-release
install -p -m 0644 %{SOURCE0} %{buildroot}%{_datadir}/myorg-release/LICENSE

# repos and vars
install -d %{buildroot}%{_sysconfdir}/yum.repos.d %{buildroot}%{_sysconfdir}/dnf/vars
install -p -m 0644 %{SOURCE3} %{SOURCE4} %{buildroot}%{_sysconfdir}/yum.repos.d/
echo "http://localhost:8080" > %{buildroot}%{_sysconfdir}/dnf/vars/myorg_baseurl
echo "https://dl.rockylinux.org/pub/rocky" > %{buildroot}%{_sysconfdir}/dnf/vars/seed_baseurl

# keys
install -d %{buildroot}%{_sysconfdir}/pki/rpm-gpg
install -p -m 0644 %{SOURCE1} %{SOURCE2} %{buildroot}%{_sysconfdir}/pki/rpm-gpg/

%files
%license %{_datadir}/myorg-release/LICENSE
%{_sysconfdir}/myorg-release
%{_sysconfdir}/myorg-release-upstream
%{_sysconfdir}/system-release
%{_sysconfdir}/redhat-release
%config %{_sysconfdir}/system-release-cpe
%config(noreplace) %{_sysconfdir}/os-release
%config(noreplace) %{_sysconfdir}/issue
%config(noreplace) %{_sysconfdir}/issue.net
%dir %{_sysconfdir}/issue.d
%{_prefix}/lib/os-release
%{_rpmmacrodir}/macros.dist
%dir %{_datadir}/myorg-release

%files -n myorg-repos
%config(noreplace) %{_sysconfdir}/yum.repos.d/myorg.repo
%config(noreplace) %{_sysconfdir}/yum.repos.d/myorg-seed.repo
%config(noreplace) %{_sysconfdir}/dnf/vars/myorg_baseurl
%config(noreplace) %{_sysconfdir}/dnf/vars/seed_baseurl

%files -n myorg-gpg-keys
%{_sysconfdir}/pki/rpm-gpg/RPM-GPG-KEY-myorg
%{_sysconfdir}/pki/rpm-gpg/RPM-GPG-KEY-upstream-seed

%changelog
* Fri Nov 06 2026 MyOrg Lab Author <lab@myorg.example> - 10.2-1
- Initial identity packages for the capstone
