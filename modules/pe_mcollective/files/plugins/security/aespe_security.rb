module MCollective
    module Security
        # Impliments a security system that encrypts payloads using AES and secures
        # the AES encrypted data using RSA public/private key encryption.
        #
        # The design goals of this plugin are:
        #
        # - Each actor - clients and servers - can have their own set of public and
        #   private keys
        # - All actors are uniquely and cryptographically identified
        # - Requests are encrypted using the clients private key and anyone that has
        #   the public key can see the request.  Thus an atacker may see the requests
        #   given access to network or machine due to the broadcast nature of mcollective
        # - Replies are encrypted using the calling clients public key.  Thus no-one but
        #   the caller can view the contents of replies.
        # - Servers can all have their own RSA keys, or share one, or reuse keys created
        #   by other PKI using software like Puppet
        # - Requests from servers - like registration data - can be secured even to external
        #   eaves droppers depending on the level of configuration you are prepared to do
        # - Given a network where you can ensure third parties are not able to access the
        #   middleware public key distribution can happen automatically
        #
        # Configuration Options:
        # ======================
        #
        # Common Options:
        #
        #    # Enable this plugin
        #    securityprovider = aespe_security
        #
        #    # Use YAML as serializer
        #    plugin.aespe.serializer = yaml
        #
        #    # Send our public key with every request so servers can learn it
        #    plugin.aespe.send_pubkey = 1
        #
        # Clients:
        #
        #    # The clients public and private keys
        #    plugin.aespe.client_private = /home/user/.mcollective.d/user-private.pem
        #    plugin.aespe.client_public = /home/user/.mcollective.d/user.pem
        #
        # Servers:
        #
        #    # Where to cache client keys or find manually distributed ones
        #    plugin.aespe.client_cert_dir = /etc/mcollective/ssl/clients
        #
        #    # Cache public keys promiscuously from the network
        #    plugin.aespe.learn_pubkeys = 1
        #
        #    # The servers public and private keys
        #    plugin.aespe.server_private = /etc/mcollective/ssl/server-private.pem
        #    plugin.aespe.server_public = /etc/mcollective/ssl/server-public.pem
        #
        #    # Maximum age of messages allowed through this plugin
        #    plugin.aespe.maximum_age = 5
        class Aespe_security<Base
            def decodemsg(msg)
                body = deserialize(msg.payload)

                # if we get a message that has a pubkey attached and we're set to learn
                # then add it to the client_cert_dir this should only happen on servers
                # since clients will get replies using their own pubkeys
                if @config.pluginconf.include?("aespe.learn_pubkeys") && @config.pluginconf["aespe.learn_pubkeys"] == "1"
                    if body.include?(:sslpubkey)
                        if client_cert_dir
                            certname = certname_from_callerid(body[:callerid])
                            if certname
                                certfile = "#{client_cert_dir}/#{certname}.pem"
                                unless File.exist?(certfile)
                                    Log.debug("Caching client cert in #{certfile}")
                                    File.open(certfile, "w") {|f| f.print body[:sslpubkey]}
                                end
                            end
                        end
                    end
                end

                cryptdata = {:key => body[:sslkey], :data => body[:body]}

                if @initiated_by == :client
                    body[:body] = deserialize(decrypt(cryptdata, nil))
                else
                    body[:body] = deserialize(decrypt(cryptdata, body[:callerid]))
                    body[:body] = body[:body][:m] unless expired?(body[:body])
                end

                return body
            rescue OpenSSL::PKey::RSAError
                raise MsgDoesNotMatchRequestID, "Could not decrypt message using our key, possibly directed at another client"

            rescue Exception => e
                Log.warn("Could not decrypt message from client: #{e.class}: #{e}")
                raise SecurityValidationFailed, "Could not decrypt message"
            end

            # Encodes a reply
            def encodereply(sender, target, msg, requestid, requestcallerid)
                crypted = encrypt(serialize(msg), requestcallerid)

                req = create_reply(requestid, sender, target, crypted[:data])
                req[:sslkey] = crypted[:key]

                serialize(req)
            end

            # Encodes a request msg
            def encoderequest(sender, target, msg, requestid, filter={}, target_agent=nil, target_collective=nil)
                timestamped_msg = {:m => msg, :t => Time.now.utc.to_f}

                crypted = encrypt(serialize(timestamped_msg), callerid)

                req = create_request(requestid, target, filter, crypted[:data], @initiated_by, target_agent, target_collective)
                req[:sslkey] = crypted[:key]

                if @config.pluginconf.include?("aespe.send_pubkey") && @config.pluginconf["aespe.send_pubkey"] == "1"
                    if @initiated_by == :client
                        req[:sslpubkey] = File.read(client_public_key)
                    else
                        req[:sslpubkey] = File.read(server_public_key)
                    end
                end

                serialize(req)
            end

            # Verifies the age of a message passes our local policy
            def expired?(msg)
                message_age = Time.now.utc.to_f - msg[:t]

                raise(SecurityValidationFailed, "Received message is #{message_age}s old expected < #{max_request_age}, perhaps a replay attack") if message_age > max_request_age
            end

            # Serializes a message using the configured encoder
            def serialize(msg)
                serializer = @config.pluginconf["aespe.serializer"] || "marshal"

                Log.debug("Serializing using #{serializer}")

                case serializer
                    when "yaml"
                        return YAML.dump(msg)
                    else
                        return Marshal.dump(msg)
                end
            end

            # De-Serializes a message using the configured encoder
            def deserialize(msg)
                serializer = @config.pluginconf["aespe.serializer"] || "marshal"

                Log.debug("De-Serializing using #{serializer}")

                case serializer
                    when "yaml"
                        return YAML.load(msg)
                    else
                        return Marshal.load(msg)
                end
            end

            # sets the caller id to the md5 of the public key
            def callerid
                if @initiated_by == :client
                    return "cert=#{File.basename(client_public_key).gsub(/\.pem$/, '')}"
                else
                    # servers need to set callerid as well, not usually needed but
                    # would be if you're doing registration or auditing or generating
                    # requests for some or other reason
                    return "cert=#{File.basename(server_public_key).gsub(/\.pem$/, '')}"
                end
            end

            def encrypt(string, certid)
                if @initiated_by == :client
                    @ssl ||= SSL.new(client_public_key, client_private_key)

                    Log.debug("Encrypting message using private key")
                    return @ssl.encrypt_with_private(string)
                else
                    # when the server is initating requests like for registration
                    # then the certid will be our callerid
                    if certid == callerid
                        Log.debug("Encrypting message using private key #{server_private_key}")

                        ssl = SSL.new(server_public_key, server_private_key)
                        return ssl.encrypt_with_private(string)
                    else
                        Log.debug("Encrypting message using public key for #{certid}")

                        ssl = SSL.new(public_key_path_for_client(certid))
                        return ssl.encrypt_with_public(string)
                    end
                end
            end

            def decrypt(string, certid)
                if @initiated_by == :client
                    @ssl ||= SSL.new(client_public_key, client_private_key)

                    Log.debug("Decrypting message using private key")
                    return @ssl.decrypt_with_private(string)
                else
                    Log.debug("Decrypting message using public key for #{certid}")

                    ssl = SSL.new(public_key_path_for_client(certid))
                    return ssl.decrypt_with_public(string)
                end
            end

            # On servers this will look in the aespe.client_cert_dir for public
            # keys matching the clientid, clientid is expected to be in the format
            # set by callerid
            def public_key_path_for_client(clientid)
                raise "Unknown callerid format in '#{clientid}'" unless clientid.match(/^cert=(.+)$/)

                clientid = $1

                client_cert_dir + "/#{clientid}.pem"
            end

            # Figures out the client private key either from MCOLLECTIVE_AESPE_PRIVATE or the
            # plugin.aespe.client_private config option
            def client_private_key
                return ENV["MCOLLECTIVE_AESPE_PRIVATE"] if ENV.include?("MCOLLECTIVE_AESPE_PRIVATE")

                raise("No plugin.aespe.client_private configuration option specified") unless @config.pluginconf.include?("aespe.client_private")

                return @config.pluginconf["aespe.client_private"]
            end

            # Figures out the client public key either from MCOLLECTIVE_AESPE_PUBLIC or the
            # plugin.aespe.client_public config option
            def client_public_key
                return ENV["MCOLLECTIVE_AESPE_PUBLIC"] if ENV.include?("MCOLLECTIVE_AESPE_PUBLIC")

                raise("No plugin.aespe.client_public configuration option specified") unless @config.pluginconf.include?("aespe.client_public")

                return @config.pluginconf["aespe.client_public"]
            end

            # Figures out the server public key from the plugin.aespe.server_public config option
            def server_public_key
                raise("No aespe.server_public configuration option specified") unless @config.pluginconf.include?("aespe.server_public")
                return @config.pluginconf["aespe.server_public"]
            end

            # Figures out the server private key from the plugin.aespe.server_private config option
            def server_private_key
                raise("No plugin.aespe.server_private configuration option specified") unless @config.pluginconf.include?("aespe.server_private")
                @config.pluginconf["aespe.server_private"]
            end

            # Figures out where to get client public certs from the plugin.aespe.client_cert_dir config option
            def client_cert_dir
                raise("No plugin.aespe.client_cert_dir configuration option specified") unless @config.pluginconf.include?("aespe.client_cert_dir")
                @config.pluginconf["aespe.client_cert_dir"]
            end

            # Takes our cert=foo callerids and return the foo bit else nil
            def certname_from_callerid(id)
                if id =~ /^cert=(.+)/
                    return $1
                else
                    return nil
                end
            end

            # Whats the maximum age of a request we will consider valid
            def max_request_age
                if @config.pluginconf.include?("aespe.maximum_age")
                    @max_request_age ||= @config.pluginconf["aespe.maximum_age"].to_i
                else
                    @max_request_age ||= 5
                end
            end
        end
    end
end
