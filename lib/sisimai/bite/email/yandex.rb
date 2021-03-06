module Sisimai::Bite::Email
  module Yandex
    # Sisimai::Bite::Email::Yandex parses a bounce email which created by
    # Yandex.Mail. Methods in the module are called from only Sisimai::Message.
    class << self
      # Imported from p5-Sisimail/lib/Sisimai/Bite/Email/Yandex.pm
      require 'sisimai/bite/email'

      Re0 = {
        :from   => %r/\Amailer-daemon[@]yandex[.]ru\z/,
      }
      Re1 = {
        :begin  => %r/\AThis is the mail system at host yandex[.]ru[.]/,
        :rfc822 => %r|\AContent-Type: message/rfc822|,
        :endof  => %r/\A__END_OF_EMAIL_MESSAGE__\z/,
      }
      Indicators = Sisimai::Bite::Email.INDICATORS

      def description; return 'Yandex.Mail: http://www.yandex.ru'; end
      def smtpagent;   return Sisimai::Bite.smtpagent(self); end

      # X-Yandex-Front: mxback1h.mail.yandex.net
      # X-Yandex-TimeMark: 1417885948
      # X-Yandex-Uniq: 92309766-f1c8-4bd4-92bc-657c75766587
      # X-Yandex-Spam: 1
      # X-Yandex-Forward: 10104c00ad0726da5f37374723b1e0c8
      # X-Yandex-Queue-ID: 367D79E130D
      # X-Yandex-Sender: rfc822; shironeko@yandex.example.com
      def headerlist;  return ['X-Yandex-Uniq']; end
      def pattern;     return Re0; end

      # Parse bounce messages from Yandex.Mail
      # @param         [Hash] mhead       Message headers of a bounce email
      # @options mhead [String] from      From header
      # @options mhead [String] date      Date header
      # @options mhead [String] subject   Subject header
      # @options mhead [Array]  received  Received headers
      # @options mhead [String] others    Other required headers
      # @param         [String] mbody     Message body of a bounce email
      # @return        [Hash, Nil]        Bounce data list and message/rfc822
      #                                   part or nil if it failed to parse or
      #                                   the arguments are missing
      def scan(mhead, mbody)
        return nil unless mhead
        return nil unless mbody
        return nil unless mhead['x-yandex-uniq']
        return nil unless mhead['from'] =~ Re0[:from]

        dscontents = [Sisimai::Bite.DELIVERYSTATUS]
        hasdivided = mbody.split("\n")
        havepassed = ['']
        rfc822list = []     # (Array) Each line in message/rfc822 part string
        blanklines = 0      # (Integer) The number of blank lines
        readcursor = 0      # (Integer) Points the current cursor position
        recipients = 0      # (Integer) The number of 'Final-Recipient' header
        commandset = []     # (Array) ``in reply to * command'' list
        connvalues = 0      # (Integer) Flag, 1 if all the value of $connheader have been set
        connheader = {
          'date'  => '',    # The value of Arrival-Date header
          'lhost' => '',    # The value of Reporting-MTA header
        }
        v = nil

        hasdivided.each do |e|
          # Save the current line for the next loop
          havepassed << e
          p = havepassed[-2]

          if readcursor.zero?
            # Beginning of the bounce message or delivery status part
            if e =~ Re1[:begin]
              readcursor |= Indicators[:deliverystatus]
              next
            end
          end

          if readcursor & Indicators[:'message-rfc822'] == 0
            # Beginning of the original message part
            if e =~ Re1[:rfc822]
              readcursor |= Indicators[:'message-rfc822']
              next
            end
          end

          if readcursor & Indicators[:'message-rfc822'] > 0
            # After "message/rfc822"
            if e.empty?
              blanklines += 1
              break if blanklines > 1
              next
            end
            rfc822list << e

          else
            # Before "message/rfc822"
            next if readcursor & Indicators[:deliverystatus] == 0
            next if e.empty?

            if connvalues == connheader.keys.size
              # Final-Recipient: rfc822; kijitora@example.jp
              # Original-Recipient: rfc822;kijitora@example.jp
              # Action: failed
              # Status: 5.1.1
              # Remote-MTA: dns; mx.example.jp
              # Diagnostic-Code: smtp; 550 5.1.1 <kijitora@example.jp>... User Unknown
              #
              # --367D79E130D.1417885948/forward1h.mail.yandex.net
              # Content-Description: Undelivered Message
              # Content-Type: message/rfc822
              v = dscontents[-1]

              if cv = e.match(/\A[Ff]inal-[Rr]ecipient:[ ]*(?:RFC|rfc)822;[ ]*([^ ]+)\z/)
                # Final-Recipient: rfc822; kijitora@example.jp
                if v['recipient']
                  # There are multiple recipient addresses in the message body.
                  dscontents << Sisimai::Bite.DELIVERYSTATUS
                  v = dscontents[-1]
                end
                v['recipient'] = cv[1]
                recipients += 1

              elsif cv = e.match(/\A[Aa]ction:[ ]*(.+)\z/)
                # Action: failed
                v['action'] = cv[1]

              elsif cv = e.match(/\A[Ss]tatus:[ ]*(\d[.]\d+[.]\d+)/)
                # Status:5.2.0
                v['status'] = cv[1]

              elsif cv = e.match(/\A[Rr]emote-MTA:[ ]*(?:DNS|dns);[ ]*(.+)\z/)
                # Remote-MTA: DNS; mx.example.jp
                v['rhost'] = cv[1].downcase

              else
                # Get error message
                if cv = e.match(/\A[Dd]iagnostic-[Cc]ode:[ ]*(.+?);[ ]*(.+)\z/)
                  # Diagnostic-Code: SMTP; 550 5.1.1 <userunknown@example.jp>... User Unknown
                  v['spec'] = cv[1].upcase
                  v['diagnosis'] = cv[2]

                elsif p =~ /\A[Dd]iagnostic-[Cc]ode:[ ]*/ && cv = e.match(/\A[ \t]+(.+)\z/)
                  # Continued line of the value of Diagnostic-Code header
                  v['diagnosis'] ||= ''
                  v['diagnosis']  += ' ' + cv[1]
                  havepassed[-1] = 'Diagnostic-Code: ' + e
                end
              end

            else
              # Content-Type: message/delivery-status
              #
              # Reporting-MTA: dns; forward1h.mail.yandex.net
              # X-Yandex-Queue-ID: 367D79E130D
              # X-Yandex-Sender: rfc822; shironeko@yandex.example.com
              # Arrival-Date: Sat,  6 Dec 2014 20:12:27 +0300 (MSK)
              if cv = e.match(/\A[Rr]eporting-MTA:[ ]*(?:DNS|dns);[ ]*(.+)\z/)
                # Reporting-MTA: dns; mx.example.jp
                next if connheader['lhost'].size > 0
                connheader['lhost'] = cv[1].downcase
                connvalues += 1

              elsif cv = e.match(/\A[Aa]rrival-[Dd]ate:[ ]*(.+)\z/)
                # Arrival-Date: Wed, 29 Apr 2009 16:03:18 +0900
                next if connheader['date'].size > 0
                connheader['date'] = cv[1]
                connvalues += 1

              else
                # <kijitora@example.jp>: host mx.example.jp[192.0.2.153] said: 550
                #    5.1.1 <kijitora@example.jp>... User Unknown (in reply to RCPT TO
                #    command)
                if cv = e.match(/[ \t][(]in reply to .*([A-Z]{4}).*/)
                  # 5.1.1 <userunknown@example.co.jp>... User Unknown (in reply to RCPT TO
                  commandset << cv[1]

                elsif cv = e.match(/([A-Z]{4})[ \t]*.*command[)]\z/)
                  # to MAIL command)
                  commandset << cv[1]
                end
              end
            end

          end
        end
        return nil if recipients.zero?
        require 'sisimai/string'

        dscontents.map do |e|
          # Set default values if each value is empty.
          connheader.each_key { |a| e[a] ||= connheader[a] || '' }
          e['command']   = commandset.shift || ''
          e['diagnosis'] = e['diagnosis'].gsub(/\\n/, '')
          e['diagnosis'] = Sisimai::String.sweep(e['diagnosis'])
          e['agent']     = self.smtpagent
        end

        rfc822part = Sisimai::RFC5322.weedout(rfc822list)
        return { 'ds' => dscontents, 'rfc822' => rfc822part }
      end

    end
  end
end

