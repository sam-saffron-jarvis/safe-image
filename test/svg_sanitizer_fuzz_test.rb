# frozen_string_literal: true

require_relative "test_helper"

module SafeImage
  # Deterministic, property-style fuzzing for the full SVG sanitizer. The CSS
  # fuzz tests cover token-level CSS; this generator stresses the higher-level
  # DOM walk where namespaces, duplicate local attribute names, href/url refs,
  # aria IDREFs, classes, and disallowed elements interact.
  class SvgSanitizerFuzzTest < TestCase
    SVG_XMLNS = "http://www.w3.org/2000/svg"
    XLINK_XMLNS = "http://www.w3.org/1999/xlink"
    XHTML_XMLNS = "http://www.w3.org/1999/xhtml"

    SEEDS = ENV.fetch("SAFE_IMAGE_FUZZ_SEEDS", "7,101,2025,65537").split(",").map { |seed| Integer(seed) }.freeze
    DOCUMENTS_PER_SEED = Integer(ENV.fetch("SAFE_IMAGE_SVG_FUZZ_DOCUMENTS", ENV.fetch("SAFE_IMAGE_FUZZ_DOCUMENTS", "75")))
    MAX_DEPTH = 3

    ELEMENTS = %w[
      svg g defs rect circle line path text tspan textPath linearGradient stop clipPath mask marker use style
      script foreignObject image a metadata bad tref
      s:g s:rect v:line s:text s:textPath s:style s:script evil:rect evil:textPath html:script
    ].freeze

    ATTRIBUTES = %w[
      id class x y x1 y1 x2 y2 width height r d points fill stroke clip-path marker marker-mid marker-end mask href xlink:href
      aria-labelledby aria-describedby style transform opacity onload onclick y:onload html:onload data-name xml:space src
    ].freeze

    # Dense geometry so the marker-per-vertex render-cost accounting (and the
    # vertex counter) is exercised, not just single-shape paths. Kept modest so
    # a marker reference multiplies it without certainly tripping the cap, so
    # both the kept and rejected branches of the bound get fuzzed.
    DENSE_GEOMETRY = [
      "M0,0 #{'L9,9 ' * 64}",
      "M0,0 #{'L9,9 ' * 512}",
      ("1,1 " * 64).strip,
      ("2,2 " * 512).strip
    ].freeze

    VALUES = [
      "g", "safe", "10", "0", "1", "#g", "url(#g)", "URL(#g)", "url('#g')", "none", "red", "#ff0000",
      "translate(1 2)", "fill:url(#g);stroke:#000", "fill:url(http://evil.example/x);stroke:#000",
      "fill:var(--host);stroke:#000", "javascript:alert(1)", "data:image/svg+xml,<svg>",
      "http://evil.example/x", "https://evil.example/x", "//evil.example/x", "url(http://evil.example/x)",
      "url(//evil.example/x)", "url(/absolute)", "url(#)", "ur\\6c(http://evil.example/x)",
      "var(--x)", "env(safe-area-inset-top)", "attr(data-x)", "modal fixed", "title desc"
    ].freeze

    def test_generated_svg_documents_hold_sanitizer_invariants
      SEEDS.each do |seed|
        rng = Random.new(seed)
        DOCUMENTS_PER_SEED.times do |index|
          namespace = rng.rand < 0.5 ? :standalone : "u1"
          input = generated_svg(rng)
          path = write_tmp("svg-sanitize-fuzz-#{seed}-#{index}.svg", input)

          begin
            SafeImage.sanitize_svg!(path, id_namespace: namespace)
          rescue InvalidImageError, LimitError
            # Rejecting the whole document (e.g. a generated <use> cycle or
            # expansion bomb) is always a safe outcome for adversarial input.
            next
          end
          cleaned = File.read(path)
          assert_svg_invariants(cleaned, namespace, input)

          # The sanitizer output is constructed XML and must be a fixed point for
          # the same namespace choice. This mirrors svg-hush's idempotent fuzzer.
          SafeImage.sanitize_svg!(path, id_namespace: namespace)
          assert_equal cleaned, File.read(path), "not idempotent for #{input.inspect}"
        end
      end
    end

    private

    def generated_svg(rng)
      children = Array.new(rng.rand(3..8)) { generated_element(rng, 0) }.join
      <<~SVG
        <svg xmlns="#{SVG_XMLNS}" xmlns:s="#{SVG_XMLNS}" xmlns:v="#{SVG_XMLNS}" xmlns:y="#{SVG_XMLNS}" xmlns:xlink="#{XLINK_XMLNS}" xmlns:html="#{XHTML_XMLNS}" xmlns:evil="urn:evil" width="20" height="20">
          <defs><linearGradient id="g"/><clipPath id="c"/><marker id="m"/></defs>
          #{children}
        </svg>
      SVG
    end

    def generated_element(rng, depth)
      name = ELEMENTS[rng.rand(ELEMENTS.length)]
      attrs = generated_attributes(rng)
      if name.end_with?("style")
        return "<#{name}#{attrs}>#{xml_text(VALUES.sample(random: rng))}{fill:url(http://evil.example/x)} .ok{fill:url(#g)}</#{name}>"
      end

      if depth >= MAX_DEPTH || rng.rand < 0.45
        "<#{name}#{attrs}/>"
      else
        children = Array.new(rng.rand(1..3)) { generated_element(rng, depth + 1) }.join
        "<#{name}#{attrs}>#{children}</#{name}>"
      end
    end

    def generated_attributes(rng)
      ATTRIBUTES.sample(rng.rand(2..7), random: rng).map do |name|
        value = value_for_attribute(name, rng)
        %( #{name}="#{xml_attr(value)}")
      end.join
    end

    def value_for_attribute(name, rng)
      case name
      when "id"
        %w[g c m title desc host safe].sample(random: rng)
      when "class"
        ["modal fixed", "ok", "host btn-danger"].sample(random: rng)
      when "href", "xlink:href"
        ["#g", "#safe", "javascript:alert(1)", "data:image/gif,GIF89a", "defs.svg#icon", "/abs", "//evil.example/x"].sample(random: rng)
      when "d", "points"
        DENSE_GEOMETRY.sample(random: rng)
      when "marker", "marker-mid", "fill", "stroke", "clip-path", "marker-end", "mask", "style", "onload", "onclick", "y:onload", "html:onload"
        VALUES.sample(random: rng)
      when "aria-labelledby", "aria-describedby"
        ["title desc", "host", "g c"].sample(random: rng)
      else
        VALUES.sample(random: rng)
      end
    end

    def assert_svg_invariants(cleaned, namespace, input)
      doc = REXML::Document.new(cleaned)
      walk(doc.root) do |element|
        assert_allowed_element(element, input)
        assert_namespaced_identity_attrs(element, namespace, input) if namespace != :standalone
        element.attributes.each_attribute do |attr|
          assert_allowed_attribute(attr, input)
          assert_safe_attribute_value(attr, namespace, input) unless namespace_declaration?(attr)
        end
        assert_safe_style_text(element.text.to_s, namespace, input) if element.name == "style"
      end
      assert_no_active_or_fetching_surface(cleaned, input)
    end

    def walk(element, &block)
      yield element
      element.children.each { |child| walk(child, &block) if child.is_a?(REXML::Element) }
    end

    def assert_allowed_element(element, input)
      assert_includes SvgSanitizer::ALLOWED_ELEMENTS, element.name.to_s,
                      "unexpected element #{element.expanded_name.inspect} survived from #{input.inspect}"
      namespace = element.namespace.to_s
      assert namespace.empty? || namespace == SVG_XMLNS,
             "non-SVG element namespace #{namespace.inspect} survived on #{element.expanded_name.inspect} from #{input.inspect}"
    end

    def assert_allowed_attribute(attr, input)
      if namespace_declaration?(attr)
        assert_includes [SVG_XMLNS, XLINK_XMLNS], attr.value.to_s,
                        "unsafe namespace declaration #{attr.expanded_name}=#{attr.value.inspect} survived from #{input.inspect}"
        return
      end
      return if attr.expanded_name == "xlink:href" && attr.namespace.to_s == XLINK_XMLNS

      assert_empty attr.prefix.to_s, "prefixed attr #{attr.expanded_name.inspect} survived from #{input.inspect}"
      name = attr.expanded_name.to_s
      assert SvgSanitizer::ALLOWED_ATTRIBUTES.include?(name) || name.start_with?("aria-"),
             "non-allowlisted attr #{name.inspect} survived from #{input.inspect}"
      refute attr.name.to_s.downcase.start_with?("on"), "event attr #{attr.expanded_name.inspect} survived from #{input.inspect}"
    end

    def assert_safe_attribute_value(attr, namespace, input)
      value = attr.value.to_s
      refute_match(/(?:javascript|data):/i, value, "active URL survived in #{attr.expanded_name}: #{input.inspect}")
      refute_includes value, "\\", "CSS/XML escape survived in #{attr.expanded_name}: #{input.inspect}"
      refute_match(/(?:var|env|attr)\s*\(/i, value, "host-reaching CSS function survived in #{attr.expanded_name}: #{input.inspect}")
      assert_safe_url_functions(value, namespace, input)
      assert_safe_href(attr, namespace, input) if href_attribute?(attr)
    end

    def assert_safe_url_functions(value, namespace, input)
      value.scan(/url\(([^)]*)\)/i).each do |inside,|
        fragment = inside.strip.delete_prefix("'").delete_prefix('"').delete_suffix("'").delete_suffix('"')
        assert_match(/\A#[A-Za-z][\w.-]*\z/, fragment, "non-fragment url() survived from #{input.inspect}")
        assert fragment.start_with?("##{namespace}-"), "bare url() fragment survived from #{input.inspect}" if namespace != :standalone
      end
    end

    def assert_safe_href(attr, namespace, input)
      value = attr.value.to_s
      assert value.start_with?("#"), "non-fragment href survived from #{input.inspect}"
      assert value.start_with?("##{namespace}-"), "bare href fragment survived from #{input.inspect}" if namespace != :standalone
    end

    def assert_namespaced_identity_attrs(element, namespace, input)
      if (id = element.attributes["id"])
        assert id.to_s.start_with?("#{namespace}-"), "bare id survived from #{input.inspect}"
      end
      if (klass = element.attributes["class"])
        klass.to_s.split.each do |token|
          assert token.start_with?("#{namespace}-"), "bare class token #{token.inspect} survived from #{input.inspect}"
        end
      end
      %w[aria-labelledby aria-describedby].each do |name|
        element.attributes[name].to_s.split.each do |ref|
          assert ref.start_with?("#{namespace}-"), "bare ARIA IDREF #{ref.inspect} survived from #{input.inspect}"
        end
      end
    end

    def assert_safe_style_text(css, namespace, input)
      refute_includes css, "\\", "CSS escape survived in style element from #{input.inspect}"
      refute_includes css, "@", "at-rule survived in style element from #{input.inspect}"
      refute_match(/(?:javascript|data):/i, css, "active URL survived in style element from #{input.inspect}")
      assert_safe_url_functions(css, namespace, input)
    end

    def assert_no_active_or_fetching_surface(cleaned, input)
      refute_match(/<\/?(?:script|foreignObject|image|a|metadata|bad)\b/i, cleaned,
                   "active/disallowed element survived from #{input.inspect}")
      refute_match(/\s[\w.-]*:?on\w+\s*=/i, cleaned, "event attribute survived from #{input.inspect}")
    end

    def href_attribute?(attr)
      attr.expanded_name == "href" || (attr.expanded_name == "xlink:href" && attr.namespace.to_s == XLINK_XMLNS)
    end

    def namespace_declaration?(attr)
      attr.expanded_name == "xmlns" || attr.prefix.to_s == "xmlns"
    end

    def xml_attr(value)
      value.to_s.gsub("&", "&amp;").gsub('"', "&quot;").gsub("<", "&lt;").gsub(">", "&gt;")
    end

    def xml_text(value)
      value.to_s.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;")
    end
  end
end
