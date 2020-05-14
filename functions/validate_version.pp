function peadm::validate_version(
  String $version,
) {
  $supported = ($version =~ SemVerRange('>= 2019.7.0 < 2020.0.0'))

  unless $supported {
    fail(@("REASON"/L))
      This version of the puppetlabs-peadm module does not support PE ${version}.

      For PE versions older than 2019.7, please use version 1.x of the \
      puppetlabs-peadm module.

      For PE versions 2020.x and newer, check to see if a version of peadm \
      exists which supports that version of PE.

      | REASON
  }
}
