module ActsAsXapian
  # Base class for Search and Similar below
  class QueryBase
    attr_accessor :offset, :limit, :query, :matches, :query_models, :runtime, :cached_results

    def initialize_db
      self.runtime = 0.0

      ActsAsXapian.readable_init

      raise "ActsAsXapian not initialized" if ActsAsXapian.db.nil?
    end

    # Set self.query before calling this
    def initialize_query(options)
      self.runtime += Benchmark::realtime do
        @offset = options[:offset].to_i
        @limit = (options[:limit] || -1).to_i
        check_at_least = (options[:check_at_least] || 100).to_i
        sort_by_prefix = options[:sort_by_prefix]
        sort_by_ascending = options[:sort_by_ascending].nil? ? true : options[:sort_by_ascending]
        collapse_by_prefix = options[:collapse_by_prefix]
        @find_options = options[:find_options]
        @postpone_limit = !(@find_options.blank? || (@find_options[:conditions].blank? && @find_options[:joins].blank?))

        ActsAsXapian.enquire.query = self.query

        if sort_by_prefix.nil?
          ActsAsXapian.enquire.sort_by_relevance!
        else
          value = ActsAsXapian.values_by_prefix[sort_by_prefix]
          raise "couldn't find prefix '#{sort_by_prefix}'" if value.nil?
          # Xapian has inverted the meaning of ascending order to handle relevence sorting
          # "keys which sort higher by string compare are better"
          ActsAsXapian.enquire.sort_by_value_then_relevance!(value, !sort_by_ascending)
        end
        if collapse_by_prefix.nil?
          ActsAsXapian.enquire.collapse_key = Xapian.BAD_VALUENO
        else
          value = ActsAsXapian.values_by_prefix[collapse_by_prefix]
          raise "couldn't find prefix '#{collapse_by_prefix}'" if value.nil?
          ActsAsXapian.enquire.collapse_key = value
        end

        # If using find_options conditions have Xapian return the entire match set
        # TODO Revisit. This is extremely inefficient for large indices
        self.matches = ActsAsXapian.enquire.mset(@postpone_limit ? 0 : @offset, @postpone_limit ? -1 : @limit, check_at_least)
        self.cached_results = nil
      end
    end

    # Return a description of the query
    def description
      self.query.description
    end

    # Estimate total number of results
    # Note: Unreliable if using find_options with conditions or joins
    def matches_estimated
      self.matches.matches_estimated
    end

    # Return query string with spelling correction
    def spelling_correction
      correction = ActsAsXapian.query_parser.get_corrected_query_string
      correction.empty? ? nil : correction
    end

    # Return array of models found
    def results
      # If they've already pulled out the results, just return them.
      return self.cached_results unless self.cached_results.nil?

      docs = nil
      self.runtime += Benchmark::realtime do
        # Pull out all the results
        docs = self.matches.matches.map {|doc| {:data => doc.document.data, :percent => doc.percent, :weight => doc.weight, :collapse_count => doc.collapse_count} }
      end

      # Log time taken, excluding database lookups below which will be displayed separately by ActiveRecord
      ActiveRecord::Base.logger.debug("  Xapian query (%.5fs) #{self.log_description}" % self.runtime) if ActiveRecord::Base.logger

      # Group the ids by the model they belong to
      lhash = docs.inject({}) do |s,doc|
        model_name, id = doc[:data].split('-')
        (s[model_name] ||= []) << id
        s
      end

      if @postpone_limit && lhash.size == 1
        @find_options[:limit] = @limit unless @limit == -1
        @find_options[:offset] = @offset
      end

      # for each class, look up the associated ids
      chash = lhash.inject({}) do |out, (class_name, ids)|
        model = class_name.constantize # constantize is expensive do once
        found = model.with_xapian_scope(ids) { model.find(:all, @find_options) }
        out[class_name] = found.inject({}) {|s,f| s[f.id] = f; s }
        out
      end

      if @postpone_limit
        # Need to delete records not returned by the active record find
        docs.delete_if do |doc|
          model_name, id = doc[:data].split('-')
          !(chash.key?(model_name) && chash[model_name].key?(id.to_i))
        end
      end

      # add the model to each doc
      docs.each do |doc|
        model_name, id = doc[:data].split('-')
        doc[:model] = chash[model_name][id.to_i]
      end

      self.cached_results = @postpone_limit && lhash.size > 1 ? docs[@offset, @limit] : docs
    end
  end
end
