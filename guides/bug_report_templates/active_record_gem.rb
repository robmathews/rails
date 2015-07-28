begin
  require 'bundler/inline'
rescue LoadError => e
  $stderr.puts 'Bundler version 1.10 or later is required. Please update your Bundler'
  raise e
end

gemfile(true) do
  source 'https://rubygems.org'
  # Activate the gem you are reporting the issue against.
  gem 'activerecord', '4.2.3'
  gem 'sqlite3'
end

require 'active_record'
require 'minitest/autorun'
require 'logger'

# Ensure backward compatibility with Minitest 4
Minitest::Test = MiniTest::Unit::TestCase unless defined?(Minitest::Test)

# This connection will do for database-independent bug reports.
ActiveRecord::Base.establish_connection(adapter: 'sqlite3', database: ':memory:')
ActiveRecord::Base.logger = Logger.new(STDOUT)

ActiveRecord::Schema.define do
  create_table :posts, force: true do |t|
  end

  create_table :comments, force: true do |t|
    t.integer :post_id
    t.boolean :enabled
    t.string :comment
  end
end

module Searchable
  def self.included(base)
    base.extend SearchFilter
    base.extend OrChain
    base.extend Search
    base.extend VectorSearch
    base.extend ChainUtility
    base.extend Joins

    # to alter specific options per model use #define_matching_vectors class method to add options
    # defines a vector search method for postgres db.  Calling Model.matching_vector(search) expects
    # a vector column defined on the model.  by default the query is espected to use "model.vector @@ plainto_tsquery('english', :search)"
    # where :search is a comma seperated string.

    base.define_singleton_method :matching_vector do |search|
      match_terms_using_vector(search)
    end

    # like the matching_vector method, this has the same defaults but matches based on queries that do not equal :search
    base.define_singleton_method :non_matching_vector do |search|
      match_terms_using_vector(search, :without => true)
    end
  end

  module SearchFilter
    def search_filter(search = '')
      #search is coming from params, so it should be handled as a string
      search.respond_to?(:to_s) ? search = search.to_s : return
      # yield the scope if search term is valid.  Define validation in define_search_filter within class
      unless (defined_search_filter? ? self.send(:defined_search_filter, search) : default_search_filter(search))
        yield
      else
        all
      end
    end

    def define_search_filter(&block)
      #add a different filter for the class
      self.define_singleton_method :defined_search_filter do
        block.call
      end
    end

    private
    def defined_search_filter?
      self.respond_to?(:defined_search_filter)
    end

    def default_search_filter(search = '')
      search.nil? || search.strip.empty?
    end
  end

  module Search
    def search_or_chain(search, *args)
      args.last.is_a?(Hash) && args.last[:search].present? ? args.unshift(search) : args.push({:search => search})
      search_filter(search) {or_chain(*args)}
    end

    def simple_search(search, query)
      search = *search
      search.map! do |term|
        real_simple_search(term, query)
      end
      search.one? ? search.first : or_chain(*search)
    end

    def real_simple_search(search, query)
      if query.is_a?(Hash)
        search_filter(search) {where(query)}
      else
        search_filter(search) {where(query + sanitize("%#{search.to_s.strip}%"))}
      end
    end

    def searchable_by_id(search, query = nil)
      search_filter(search) do
        query ||= "#{table_name}.id = :search"
        search.to_s =~ /\A\s*\d+\s*\Z/ ? where(query, :search => search.to_i) : where("1=0")
      end
    end

    def matching_searchable(search, id_search = :id_searches, text_search = :text_searches)
      return unless respond_to?(id_search) && respond_to?(text_search)
      search_filter(search) do
        if search.to_s =~ /\A\s*\d+\s*\Z/
          send(id_search, search)
        else
          send(text_search, search)
        end
      end
    end

    def widened_search(search, query, search_scope = self)
      return unless search.map(&:class).uniq.one?
      case search.first
      when String
        search_scope.simple_search(search, query)
      when Numeric, self
        search = search.map(&:id) if search.is_a?(self)
        search_scope.searchable_by_id(search)
      else
        none
      end
    end
  end

  module OrChain
    def or_chain(*args)
      create_chain(chain_args(args))
    ensure
      clear_joins_scopes_and_hash
    end

    private
    def chain_args(args = [])
      options = (args.last.is_a?(Hash) && !is_a_method?(args.last.first)) ? args.extract_options! : {}
      search = options[:search] || ""
      args = args.map do |arg|
        if is_a_method?(arg)
          search.present? ? send(arg, search) : extract_method_and_arguments(arg)
        else
          arg
        end
      end
      collect_joins_scopes(args)
      arel_args(args)
    end

    def create_chain(arelized_args = [])
      chain, arelized_args = remove_first(arelized_args)
      arelized_args.each do |arg|
        chain = chain.send(:or, arg)
      end
      current_scope_chain(chain)
    end
  end

  module ChainUtility
    private
    def remove_first(args)
      removed, args = args.partition{|arg| arg == args.first}
      [removed.first, args]
    end

    def arel_args(args = [])
      Array.wrap(args).map{|arg| arg.arel.constraints.first}
    end

    def is_a_method?(testing)
      return true if method_like?(testing)
      method_with_arguments?(testing)
    end

    def method_like?(testing)
      (testing.is_a?(Symbol) || testing.is_a?(String)) && respond_to?(testing)
    end

    def method_with_arguments?(testing)
      (testing.is_a?(Array) && respond_to?(testing.first)) || (testing.is_a?(Hash) && respond_to?(testing.first.first))
    end

    def extract_method_and_arguments(method)
      raise "#{method} must be a callable method" if !is_a_method?(method)
      if method_with_arguments?(method)
        if method.is_a?(Hash)
          method = [method.first.first, method.first.last]
        elsif method.is_a?(Array)
          method = [method.first,method.last]
        end
      end
      method = *method
      send(*method)
    end
  end

  module VectorSearch
    MATCHING_VECTOR = :matching_vector
    NON_MATCHING_VECTOR = :non_matching_vector
    def define_matching_vector(*args)
      options = args.extract_options!
      name = vector_method_name(MATCHING_VECTOR, args.first)
      define_singleton_method name do |search|
        match_terms_using_vector(search, options)
      end
    end

    def define_non_matching_vector(*args)
      options = args.extract_options!
      name = vector_method_name(NON_MATCHING_VECTOR, args.first)
      define_singleton_method name do |search|
        match_terms_using_vector(search, options.merge(:without => true))
      end
    end

    def define_matching_vectors(*args)
      options = args.extract_options!
      define_matching_vector(vector_method_name(MATCHING_VECTOR, args.first), options)
      define_non_matching_vector(vector_method_name(NON_MATCHING_VECTOR, "non_#{args.first.to_s}"), options)
    end

    private
    #valid options [:without, :tsvector, :column, :name]

    def vector_method_name(default_name, name)
      name && name.to_s != default_name.to_s ? name : default_name
    end

    def match_terms_using_vector(search, options = {})
      without = options[:without]
      vector_column = options[:column] || self.model_name.plural + ".vector"
      term_hash = {}
      search_array = search.to_s.split(",").reject(&:blank?).map.with_index do |term,index|
        term_key = "search#{index}"
        term_hash[term_key.to_sym] = term.to_s.strip
        vector_query(vector_column, term_key, without, join_tsquery(options[:tsvector]))
      end
      where(search_array.join(without ? " and " : " or "), term_hash)
    end

    def join_tsquery(array)
      if array.blank? || (array.respond_to?(:size) && array.size != 2)
        "plainto_tsquery('english'"
      else
        "#{array.first}('#{array.last}'"
      end
    end

    def vector_query(table_and_column, term_key, without, tsvector_choice)
      prefix = without ? "not " : ""
      "#{prefix}#{table_and_column} @@ #{tsvector_choice}, :#{term_key})"
    end
  end

  module Joins
    attr_writer :current_joins_values, :current_eager_load_values, :current_preload_values, :current_includes_values

    private
    def collect_joins_scopes(scopes = [])
      scopes = *scopes
      scopes.each do |_scope|
        collect_current_scope_values(_scope)
      end
      joins_hash([current_joins_values, current_eager_load_values, current_preload_values, current_includes_values])
    end

    def current_joins_values
      @current_joins_values ||= []
    end

    def current_eager_load_values
      @current_eager_load_values ||= []
    end

    def current_preload_values
      @current_preload_values ||= []
    end

    def current_includes_values
      @current_includes_values ||= []
    end

    def collect_current_scope_values(_scope)
      if _scope
        self.current_joins_values      = ( (current_joins_values || [])      + _scope.current_scope.joins_values      ).uniq
        self.current_eager_load_values = ( (current_eager_load_values || []) + _scope.current_scope.eager_load_values ).uniq
        self.current_preload_values    = ( (current_preload_values || [])    + _scope.current_scope.preload_values    ).uniq
        self.current_includes_values   = ( (current_includes_values || [])   + _scope.current_scope.includes_values   ).uniq
      end
    end

    def joins_hash(collection = [])
      @joins_hash ||= {}
      if collection.present?
        [:joins, :eager_load, :preload, :includes].each_with_index do |join_type, index|
          @joins_hash[join_type] = collection[index]
        end
         @joins_hash.delete_if {|meth, args| args.empty?}
      end
      @joins_hash
    end

    def current_scope_chain(arel_scope)
      current_chain = self
      joins_hash.each{ |meth, args| current_chain = send(meth, *args) } if joins_hash.present?
      current_chain.where(arel_scope)
    ensure
      clear_joins_scopes_and_hash
    end

    def collect_and_use_current_joins_scopes(_scope)
      collect_joins_scopes(_scope)
      current_scope_chain.where(_scope)
    ensure
      clear_joins_scopes_and_hash
    end

    def clear_joins_hash
      @joins_hash = {}
    end

    def clear_joins_scopes
      @current_joins_values = @current_eager_load_values = @current_preload_values = @current_includes_values = []
    end

    def clear_joins_scopes_and_hash
      clear_joins_hash
      clear_joins_scopes
    end
  end
end

class Post < ActiveRecord::Base
  has_many :comments

end

class Comment < ActiveRecord::Base
  include Searchable
  belongs_to :post
  default_scope {where(:enabled=>true)}
  scope :snarky, lambda {where(:comment=>"cat pictures")}
  scope :smart, lambda {where(:comment=>"try googling it")}
  scope :typical, lambda {Comment.or_chain(:snarky,:smart)}
end

class BugTest < Minitest::Test
  def test_association_stuff
    # post = Post.create!
    # post.comments << Comment.create!
    @comments = Comment.typical.to_a


    # assert_equal 1, post.comments.count
    # assert_equal 1, Comment.count
    # assert_equal post.id, Comment.first.post.id
  end
end
