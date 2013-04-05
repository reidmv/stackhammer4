class pe_mcollective::shared_key_files::ca inherits pe_mcollective::shared_key_files {
  # This class is applied on the pe_mcollective::ca node (certificate
  # authority), which is responsible for generating all the key files.
  # Because the files are local to the CA node, they should be sourced
  # from the local filesystem instead of being fed into the content
  # parameter (the method used to ship the files to all other nodes in
  # the environment).

  # MCollective server key files
  File['mcollective-public.pem'] {
    source  => '/etc/puppetlabs/puppet/ssl/public_keys/pe-internal-mcollective-servers.pem',
    content => undef,
    require +> Pe_mcollective::Puppet_certificate['pe-internal-mcollective-servers'],
  }
  File['mcollective-private.pem'] {
    source  => '/etc/puppetlabs/puppet/ssl/private_keys/pe-internal-mcollective-servers.pem',
    content => undef,
    require +> Pe_mcollective::Puppet_certificate['pe-internal-mcollective-servers'],
  }
  File['mcollective-cert.pem'] {
    source  => '/etc/puppetlabs/puppet/ssl/certs/pe-internal-mcollective-servers.pem',
    content => undef,
    require +> Pe_mcollective::Puppet_certificate['pe-internal-mcollective-servers'],
  }

  # Public key files for pe_mcollective clients (peadmin, puppet-dashboard)
  File['peadmin-public.pem'] {
    source  => '/etc/puppetlabs/puppet/ssl/public_keys/pe-internal-peadmin-mcollective-client.pem',
    content => undef,
    require => Pe_mcollective::Puppet_certificate['pe-internal-peadmin-mcollective-client'],
  }
  File['puppet-dashboard-public.pem'] {
    source  => '/etc/puppetlabs/puppet/ssl/public_keys/pe-internal-puppet-console-mcollective-client.pem',
    content => undef,
    require +> Pe_mcollective::Puppet_certificate['pe-internal-puppet-console-mcollective-client'],
  }

  # PE Console client private key files (puppet-dashboard)
  File['/opt/puppet/share/puppet-dashboard/.mcollective.d/puppet-dashboard-private.pem'] {
    source  => '/etc/puppetlabs/puppet/ssl/private_keys/pe-internal-puppet-console-mcollective-client.pem',
    content => undef,
    require +> Pe_mcollective::Puppet_certificate['pe-internal-puppet-console-mcollective-client'],
  }
  File['/opt/puppet/share/puppet-dashboard/.mcollective.d/puppet-dashboard-public.pem'] {
    source  => '/etc/puppetlabs/puppet/ssl/public_keys/pe-internal-puppet-console-mcollective-client.pem',
    content => undef,
    require +> Pe_mcollective::Puppet_certificate['pe-internal-puppet-console-mcollective-client'],
  }
  File['/opt/puppet/share/puppet-dashboard/.mcollective.d/puppet-dashboard-cert.pem'] {
    source  => '/etc/puppetlabs/puppet/ssl/certs/pe-internal-puppet-console-mcollective-client.pem',
    content => undef,
    require +> Pe_mcollective::Puppet_certificate['pe-internal-puppet-console-mcollective-client'],
  }

}
