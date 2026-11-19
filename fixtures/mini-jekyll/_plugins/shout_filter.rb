# Synthetic plugin. The lab never executes _plugins/*.rb.
module Jekyll
  module ShoutFilter
    def shout(input)
      input.to_s.upcase
    end
  end
end

Liquid::Template.register_filter(Jekyll::ShoutFilter)
