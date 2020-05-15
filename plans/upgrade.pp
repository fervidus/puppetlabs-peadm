# @summary Upgrade an Extra Large stack from one .z to the next
#
plan peadm::upgrade (
  # Standard
  Peadm::SingleTargetSpec           $master_host,
  Optional[Peadm::SingleTargetSpec] $master_replica_host = undef,

  # Large
  Optional[TargetSpec]              $compiler_hosts      = undef,

  # Extra Large
  Optional[Peadm::SingleTargetSpec] $puppetdb_database_host         = undef,
  Optional[Peadm::SingleTargetSpec] $puppetdb_database_replica_host = undef,

  # Common Configuration
  String $version,

  # Other
  String[1] $stagingdir = '/tmp',
) {
  peadm::validate_version($version)

  # Ensure input valid for a supported architecture
  $arch = peadm::validate_architecture(
    $master_host,
    $master_replica_host,
    $puppetdb_database_host,
    $puppetdb_database_replica_host,
    $compiler_hosts,
  )

  # Convert inputs into targets.
  $master_target                    = peadm::get_targets($master_host, 1)
  $master_replica_target            = peadm::get_targets($master_replica_host, 1)
  $puppetdb_database_target         = peadm::get_targets($puppetdb_database_host, 1)
  $puppetdb_database_replica_target = peadm::get_targets($puppetdb_database_replica_host, 1)
  $compiler_targets                 = peadm::get_targets($compiler_hosts)

  $all_targets = peadm::flatten_compact([
    $master_target,
    $puppetdb_database_target,
    $master_replica_target,
    $puppetdb_database_replica_target,
    $compiler_targets,
  ])

  $pe_installer_targets = peadm::flatten_compact([
    $master_target,
    $puppetdb_database_target,
    $puppetdb_database_replica_target,
  ])

  # Gather trusted facts from all systems
  $trusted_facts = run_task('peadm::trusted_facts', $all_targets).reduce({}) |$memo,$result| {
    $memo + { $result.target => $result['extensions'] }
  }

  # Ensure needed trusted facts are available
  if $trusted_facts.any |$t,$ext| { $ext[peadm::oid('peadm_role')] == undef } {
    fail_plan(@(HEREDOC/L))
      Required trusted facts are not present; upgrade cannot be completed. If \
      this infrastructure was provisioned with an old version of peadm, you may \
      need to run the peadm::convert plan\
      | HEREDOC
  }

  # Determine which compilers are associated with which HA group
  $compiler_m1_targets = $compiler_targets.filter |$target| {
    ($trusted_facts[$target][peadm::oid('peadm_availability_group')]
      == $trusted_facts[$master_target[0]][peadm::oid('peadm_availability_group')])
  }

  $compiler_m2_targets = $compiler_targets.filter |$target| {
    ($trusted_facts[$target][peadm::oid('peadm_availability_group')]
      == $trusted_facts[$master_replica_target[0]][peadm::oid('peadm_availability_group')])
  }

  ###########################################################################
  # PREPARATION
  ###########################################################################

  # Support for running over the orchestrator transport relies on Bolt being
  # executed from the master using the local transport. For now, fail the plan
  # if the orchestrator is being used for the master.
  $master_target.peadm::fail_on_transport('pcp')

  # Download the PE tarball on the nodes that need it
  $platform = run_task('peadm::precheck', $master_target).first['platform']
  $tarball_filename = "puppet-enterprise-${version}-${platform}.tar.gz"
  $upload_tarball_path = "/tmp/${tarball_filename}"

  run_plan('peadm::util::retrieve_and_upload', $pe_installer_targets,
    source      => "https://s3.amazonaws.com/pe-builds/released/${version}/${tarball_filename}",
    local_path  => "${stagingdir}/${tarball_filename}",
    upload_path => $upload_tarball_path,
  )

  # Shut down Puppet on all infra targets
  run_task('service', $all_targets,
    action => 'stop',
    name   => 'puppet',
  )

  ###########################################################################
  # UPGRADE MASTER SIDE
  ###########################################################################

  # Shut down PuppetDB on CMs that use the PM's PDB PG
  run_task('service', $compiler_m1_targets,
    action => 'stop',
    name   => 'pe-puppetdb',
  )

  run_task('peadm::pe_install', $puppetdb_database_target,
    tarball               => $upload_tarball_path,
    puppet_service_ensure => 'stopped',
  )

  run_task('peadm::pe_install', $master_target,
    tarball               => $upload_tarball_path,
    puppet_service_ensure => 'stopped',
  )

  # If in use, wait until orchestrator service is healthy to proceed
  if $all_targets.any |$target| { $target.protocol == 'pcp' } {
    peadm::wait_until_service_ready('orchestrator-service', $master_target)
    wait_until_available($all_targets, wait_time => 120)
  }

  # Installer-driven upgrade will de-configure auth access for compilers.
  # Re-run Puppet immediately to fully re-enable
  run_task('peadm::puppet_runonce', [
    $master_target,
    $puppetdb_database_target,
  ])

  # The master could restart orchestration services again, in which case we
  # would have to wait for nodes to reconnect
  if $all_targets.any |$target| { $target.protocol == 'pcp' } {
    peadm::wait_until_service_ready('orchestrator-service', $master_target)
    wait_until_available($all_targets, wait_time => 120)
  }

  # Upgrade the compiler group A targets
  run_task('peadm::agent_upgrade', $compiler_m1_targets,
    server => $master_target.peadm::target_name(),
  )

  ###########################################################################
  # UPGRADE REPLICA SIDE
  ###########################################################################

  # Shut down PuppetDB on compilers that use the replica's PDB PG
  run_task('service', $compiler_m2_targets,
    action => 'stop',
    name   => 'pe-puppetdb',
  )

  run_task('peadm::pe_install', $puppetdb_database_replica_target,
    tarball               => $upload_tarball_path,
    puppet_service_ensure => 'stopped',
  )

  # Installer-driven upgrade will de-configure auth access for compilers.
  # Re-run Puppet immediately to fully re-enable
  run_task('peadm::puppet_runonce', $puppetdb_database_replica_target)

  # Run the upgrade.sh script on the master replica target
  run_task('peadm::agent_upgrade', $master_replica_target,
    server => $master_target.peadm::target_name(),
  )

  # Upgrade the compiler group B targets
  run_task('peadm::agent_upgrade', $compiler_m2_targets,
    server => $master_target.peadm::target_name(),
  )

  ###########################################################################
  # FINALIZE UPGRADE
  ###########################################################################

  # Ensure Puppet running on all infrastructure targets
  run_task('service', $all_targets,
    action => 'start',
    name   => 'puppet',
  )

  return("Upgrade of Puppet Enterprise ${arch['architecture']} succeeded.")
}
