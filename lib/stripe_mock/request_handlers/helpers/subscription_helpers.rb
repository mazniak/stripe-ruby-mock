module StripeMock
  module RequestHandlers
    module Helpers

      def get_customer_subscription(customer, sub_id)
        customer[:subscriptions][:data].find{|sub| sub[:id] == sub_id }
      end

      def resolve_subscription_changes(subscription, plans, customer, options = {})
        if subscription[:plan][:id] != plans[0][:id]
          options[:current_period_start] = Time.now.utc.to_i
        end

        subscription.merge!(custom_subscription_params(plans, customer, options))
        subscription[:items][:data] = plans.map do |plan|
          if options[:items] && options[:items].size == plans.size
            opts = options[:items] &&
              options[:items].detect { |item| item[:plan] == plan[:id] }
            Data.mock_subscription_item({ plan: plan, quantity: opts[:quantity] || 1, metadata: opts[:metadata] || {} })
          else
            Data.mock_subscription_item({ plan: plan })
          end
        end
        subscription
      end

      def custom_subscription_params(plans, cus, options = {})
        verify_trial_end(options[:trial_end]) if options[:trial_end]

        plan = plans.first if plans.size == 1

        now = Time.now.utc.to_i
        created_time = options[:created] || now
        start_time = options[:current_period_start] || now
        params = { customer: cus[:id], current_period_start: start_time, created: created_time }
        params.merge!({ :plan => (plans.size == 1 ? plans.first : nil) })
        params.merge! options.select {|k,v| k =~ /application_fee_percent|quantity|metadata|tax_percent/}
        # TODO: Implement coupon logic

        if (((plan && plan[:trial_period_days]) || 0) == 0 && options[:trial_end].nil?) || options[:trial_end] == "now"
          anchor = options[:billing_cycle_anchor]
          anchor = Time.now.utc.to_i if 'now' == anchor

          end_time = anchor || get_ending_time(start_time, plan)
          params.merge!({status: 'active', current_period_end: end_time, trial_start: nil, trial_end: nil, billing_cycle_anchor: options[:billing_cycle_anchor]})
        else
          end_time = options[:trial_end] || (Time.now.utc.to_i + plan[:trial_period_days]*86400)
          params.merge!({status: 'trialing', current_period_end: end_time, trial_start: start_time, trial_end: end_time, billing_cycle_anchor: nil})
        end

        params
      end

      def mock_subscription_invoice(sub, **params)
        update = params[:subscription_plan] && params[:subscription_plan] != sub[:items][:data][0][:plan][:id]
        params[:subscription_billing_cycle_anchor] = 'now' if update
        fake = Stripe::Invoice.upcoming(
          id: new_id('in'),
          customer: sub[:customer],
          subscription: sub[:id],
          **params
        )
        fake.date = Time.now.to_i
        line = fake.lines.data.detect {|x| x if x.subscription && !x.proration }
        period = line.period

        fake.lines.data.each do |x|
          if x.proration
            x.period.start = sub[:current_period_start]
            x.period.end = fake.date
          end
        end

        if update
          period.start = sub[:current_period_start] unless line.proration
          period.end = get_ending_time(period.start, sub[:items][:data][0][:plan])
        else
          period.start = sub[:current_period_start]
          period.end = sub[:current_period_end]
        end
        fake.period_start = period.start
        fake.period_end = period.end
        fake.paid = true
        fake.closed = true
        fake.attempted = true
        if fake.total < 0
          cus = customers[sub[:customer]]
          fake.ending_balance = fake.total.abs + cus[:account_balance]
          cus[:account_balance] = fake.ending_balance
        end
        fake.ending_balance = 0
        fake.lines.data.each do |line|
          unless line.proration
            line.subscription = sub[:id]
            line.metadata = sub[:metadata]
            line.subscription_item = sub[:items][:data][0][:id]
            line.period = period
          end
        end
        fake.status = 'paid'
        invoices[fake.id] = fake.as_json
      end

      def add_subscription_to_customer(cus, sub)
        if sub[:trial_end].nil? || sub[:trial_end] == "now"
          id = new_id('ch')
          charges[id] = Data.mock_charge(
            :id => id,
            :customer => cus[:id],
            :amount => (sub[:plan] ? sub[:plan][:amount] : total_items_amount(sub[:items][:data]))
          )

        end

        if cus[:currency].nil?
          cus[:currency] = sub[:items][:data][0][:plan][:currency]
        elsif cus[:currency] != sub[:items][:data][0][:plan][:currency]
          raise Stripe::InvalidRequestError.new( "Can't combine currencies on a single customer. This customer has had a subscription, coupon, or invoice item with currency #{cus[:currency]}", 'currency', http_status: 400)
        end
        cus[:subscriptions][:total_count] = (cus[:subscriptions][:total_count] || 0) + 1
        cus[:subscriptions][:data].unshift sub
      end

      def delete_subscription_from_customer(cus, subscription)
        cus[:subscriptions][:data].reject!{|sub|
          sub[:id] == subscription[:id]
        }
        cus[:subscriptions][:total_count] -=1
      end

      # `intervals` is set to 1 when calculating current_period_end from current_period_start & plan
      # `intervals` is set to 2 when calculating Stripe::Invoice.upcoming end from current_period_start & plan
      def get_ending_time(start_time, plan, intervals = 1)
        return start_time unless plan

        case plan[:interval]
        when "week"
          start_time + (604800 * (plan[:interval_count] || 1) * intervals)
        when "month"
          (Time.at(start_time).to_datetime >> ((plan[:interval_count] || 1) * intervals)).to_time.to_i
        when "year"
          (Time.at(start_time).to_datetime >> (12 * intervals)).to_time.to_i # max period is 1 year
        else
          start_time
        end
      end

      def verify_trial_end(trial_end)
        if trial_end != "now"
          if !trial_end.is_a? Integer
            raise Stripe::InvalidRequestError.new('Invalid timestamp: must be an integer', nil, http_status: 400)
          elsif trial_end < Time.now.utc.to_i
            raise Stripe::InvalidRequestError.new('Invalid timestamp: must be an integer Unix timestamp in the future', nil, http_status: 400)
          elsif trial_end > Time.now.utc.to_i + 31557600*5 # five years
            raise Stripe::InvalidRequestError.new('Invalid timestamp: can be no more than five years in the future', nil, http_status: 400)
          end
        end
      end

      def total_items_amount(items)
        total = 0
        items.each { |i| total += (i[:quantity] || 1) * i[:plan][:amount] }
        total
      end
    end
  end
end
