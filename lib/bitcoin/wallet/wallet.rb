module Bitcoin::Wallet

  class Wallet

    attr_reader :keystore
    def initialize storage, keystore, selector
      @storage = storage
      @keystore = keystore
      @selector = selector
    end

    def get_txouts(unconfirmed = false)
      txouts = @keystore.keys.map {|k|
        @storage.get_txouts_for_address(k[:addr])}.flatten.uniq
      txouts.select! {|o| !!o.get_tx.get_block}  unless unconfirmed
    end

    def get_balance
      values = get_txouts.select{|o| !o.get_next_in}.map(&:value)
      ([0] + values).inject(:+)
    end

    def addrs
      @keystore.keys.map{|k| k[:key].addr}
    end

    def add_key key
      @keystore.add_key(key)
    end

    def label old, new
      @keystore.label_key(old, new)
    end

    def flag name, flag, value
      @keystore.flag_key(name, flag, value)
    end

    def list
      @keystore.keys.map do |key|
        [key, @storage.get_balance(Bitcoin.hash160_from_address(key[:addr]))]
      end
    end

    def get_new_addr
      @keystore.new_key.addr
    end

    def get_selector
      @selector.new(get_txouts)
    end

    # outputs = [<addr>, <value>]
    # [:address, <addr>, <value>]
    # [:multisig, 2, 3, <addr>, <addr>, <addr>, <value>]
    def tx outputs, fee = 0, change_policy = :back
      output_value = outputs.map{|o|o[-1]}.inject(:+)

      prev_outs = get_selector.select(output_value)
      return nil  if !prev_outs

      tx = Bitcoin::Protocol::Tx.new(nil)

      input_value = prev_outs.map(&:value).inject(:+)
      return nil  unless input_value >= (output_value + fee)

      outputs.each do |type, *addrs, value|
        script = nil
        case type
        when :pubkey
          pubkey = @keystore.key(addrs[0])
          raise "Public key for #{addrs[0]} not known"  unless pubkey
          binding.pry
          script = Bitcoin::Script.to_pubkey_script(pubkey[:key].pub)
        when :address
          if Bitcoin.valid_address?(addrs[0])
            addr = addrs[0]
          else
            addr = @keystore.key(addrs[0])[:addr] rescue nil
          end
          raise "Invalid address: #{addr}"  unless Bitcoin.valid_address?(addr)
          script = Bitcoin::Script.to_address_script(addr)
        when :multisig
          m, *addrs = addrs
          addrs.map!{|a| keystore.key(a)[:key].pub rescue raise("public key for #{a} not known")}
          script = Bitcoin::Script.to_multisig_script(m, *addrs)
        else
          raise "unknown script type: #{type}"
        end
        txout = Bitcoin::Protocol::TxOut.new(value, script.bytesize, script)
        tx.add_out(txout)
      end

      change_value = input_value - output_value - fee
      if change_value > 0
        change_addr = get_change_addr(change_policy,prev_outs.sample.get_address)
        change = Bitcoin::Protocol::TxOut.value_to_address(input_value - output_value - fee, change_addr)
        tx.add_out(change)
      end

      prev_outs.each_with_index do |prev_out, idx|
        prev_tx = prev_out.get_tx
        txin = Bitcoin::Protocol::TxIn.new(prev_tx.binary_hash,
          prev_tx.out.index(prev_out), 0)
        tx.add_in(txin)
      end

      sigs_missing = false
      prev_outs.each_with_index do |prev_out, idx|
        prev_tx = prev_out.get_tx
        pk_script = Bitcoin::Script.new(prev_out.pk_script)
        if pk_script.is_pubkey? || pk_script.is_hash160?
          key = @keystore.key(prev_out.get_address)
          if key && key[:key] && !key[:key].priv.nil?
            sig_hash = tx.signature_hash_for_input(idx, prev_tx)
            sig = key[:key].sign(sig_hash)
            script_sig = Bitcoin::Script.to_pubkey_script_sig(sig, [key[:key].pub].pack("H*"))
          end
        elsif pk_script.is_multisig?
          sigs = []
          required_sigs = pk_script.get_signatures_required
          pk_script.get_multisig_pubkeys.each do |pub|
            break  if sigs.size == required_sigs
            key = @keystore.key(pub.unpack("H*")[0])[:key] rescue nil
            next  unless key && key.priv
            sig_hash = tx.signature_hash_for_input(idx, prev_tx)
            sig = [key.sign(sig_hash), "\x01"].join
            sigs << sig
          end
          if sigs.size == required_sigs
            script_sig = Bitcoin::Script.to_multisig_script_sig(*sigs)
          else
            puts "Need #{required_sigs} signatures, only have #{sigs.size} private keys"
            sigs_missing = true
          end
        end
        if script_sig
          tx.in[idx].script_sig_length = script_sig.bytesize
          tx.in[idx].script_sig = script_sig
          raise "Signature error"  unless tx.verify_input_signature(idx, prev_tx)
        else
          return Bitcoin::Wallet::TxDP.new([tx, *prev_outs.map(&:get_tx)])
        end
      end

      Bitcoin::Protocol::Tx.new(tx.to_payload)
    end

    protected

    def get_change_addr(policy, in_addr)
      case policy
      when :first
        @keystore.keys[0].addr
      when :random
        @keystore.keys.sample.addr
      when :new
        @keystore.new_key.addr
      when :back
        in_addr
      else
        policy
      end
    end

  end

end
