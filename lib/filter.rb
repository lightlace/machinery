class Filter
  attr_accessor :element_filters

  def initialize(filter_definition)
    @element_filters = {}

    filter_definition.scan(/\"?([^,]*?)=([^\"]*)\"?,?/).each do |path, matcher_definition|
      @element_filters[path] = ElementFilter.new(path, matcher_definition.split(","))
    end
  end

  def matches?(path, value)
    filter = filter_for(path)
    return false if !filter

    filter.matches?(value)
  end

  def filter_for(path)
    element_filters[path]
  end
end
