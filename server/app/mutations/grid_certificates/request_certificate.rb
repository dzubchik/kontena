require 'timeout'

require_relative 'common'
require_relative '../../services/logging'

module GridCertificates
  class RequestCertificate < Mutations::Command
    include Common
    include Logging
    include WaitHelper

    required do
      model :grid, class: Grid

      array :domains do
        string
      end
      string :cert_type, in: ['cert', 'chain', 'fullchain'], default: 'fullchain'
    end

    optional do
      array :linked_services do
        string
      end
    end

    def validate
      self.domains.each do |domain|
        domain_authz = get_authz_for_domain(self.grid, domain)

        if domain_authz
          if domain_authz.authorization_type == 'dns-01'
            # Check that the expected DNS record is already in place
            unless validate_dns_record(domain, domain_authz.challenge_opts['record_content'])
              add_error(:dns_record, :invalid, "Expected DNS record not present for domain #{domain}")
            end
          end
        else
          add_error(:authorization, :not_found, "Domain authorization not found for domain #{domain}")
        end

      end
    end

    def verify_domain(domain)
      domain_authorization = get_authz_for_domain(self.grid, domain)
      challenge = acme_client.challenge_from_hash(domain_authorization.challenge)
      if domain_authorization.state == :created
        info 'requesting verification for domain #{domain}'
        success = challenge.request_verification
        if success
          domain_authorization.state = :requested
          domain_authorization.save
        else
          add_error(:request_verification, :failed, "Requesting verification failed")
        end
      end

      wait_until!("domain verification for #{domain} is valid", interval: 1, timeout: 30, threshold: 10) {
        challenge.verify_status != 'pending'
      }

      case challenge.verify_status
      when 'valid'
        domain_authorization.state = :validated
      when 'invalid'
        domain_authorization.state = :invalid
        add_error(:challenge, :invalid, challenge.error['detail'])
      end

      domain_authorization.save
    rescue Timeout::Error
      warn 'timeout while waiting for DNS verfication status'
      add_error(:challenge_verify, :timeout, 'Challenge verification timeout')
    rescue Acme::Client::Error => exc
      error "#{exc.class.name}: #{exc.message}"
      error exc.backtrace.join("\n") if exc.backtrace
      add_error(:acme_client, :error, exc.message)
    end

    def has_errors?
      return true if @errors && @errors.size > 0
      false
    end

    def execute

      self.domains.each do |domain|
        verify_domain(domain)
      end

      # some domain verifications has failed, errors already added
      return if has_errors?

      csr = Acme::Client::CertificateRequest.new(names: self.domains)
      certificate = acme_client.new_certificate(csr)
      cert_priv_key = certificate.request.private_key.to_pem
      certificate_pem = nil
      case self.cert_type
        when 'fullchain'
          certificate_pem = certificate.fullchain_to_pem
        when 'chain'
          certificate_pem = certificate.chain_to_pem
        when 'cert'
          certificate_pem = certificate.to_pem
      end

      certificate_model = Certificate.create!(
        grid: self.grid,
        subject: self.domains[0],
        alt_names: self.domains[1..-1],
        valid_until: certificate.x509.not_after,
        private_key: cert_priv_key,
        certificate: certificate_pem
      )

      certificate_model

    rescue Acme::Client::Error => exc
      error "#{exc.class.name}: #{exc.message}"
      error exc.backtrace.join("\n") if exc.backtrace
      add_error(:acme_client, :error, exc.message)
    end


    def acme_client
      @acme_client ||= acme_client(self.grid)
    end

  end
end

