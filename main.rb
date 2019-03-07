require 'json'
require 'open-uri'
require 'timeout'
require "minitest/autorun"

require 'nokogiri'

class API
    def initialize(api_url, api_key)
        raise ArgumentError, "API URL can't be empty" if not api_url or api_url.strip.empty?
        raise ArgumentError, "API key can't be empty" if not api_key or api_key.strip.empty?

        @api_url = api_url
        @api_key = api_key
        @headers = {
            "X-Integros-Key" => @api_key
        }
    end

    def zone_link(publisher, zone)
        req = open(@api_url + "/v1/adserver/publishers/#{publisher}/zones/#{zone}/link", @headers)
        resp = req.read
        json = JSON.parse(resp)
        json['result']
    end
end

class Targets
    attr_reader :hits

    def initialize(minimum_hits, precision_treshold, target_probabilities)
        @minimum_hits = minimum_hits
        @precision_treshold = precision_treshold
        @hits = 0
        @buckets = Hash.new(0)
        @target_probabilities = target_probabilities
    end

    def record(bucket_name)
        raise ArgumentError, "Unexpected bucket name, `#{bucket_name}`. Want one of #{@target_probabilities.keys}" unless @target_probabilities.has_key? bucket_name
        raise "bucket `#{bucket_name}` got a hit, none expected" if @target_probabilities[bucket_name] == 0

        @hits += 1
        @buckets[bucket_name] += 1
    end

    def satisfied?
        return false if @hits < @minimum_hits
        return false if not @buckets.keys.empty? and @buckets.all? {|k,v| v <= 0 }

        @target_probabilities.each { |name, target|
            return false if (@buckets[name].fdiv(@hits) - target).abs > @precision_treshold
        }

        return true
    end

    def to_s
        out = "[#{@hits}/#{@minimum_hits} records"
        @buckets.each { |name, count|
            out << ", `#{name}` #{count}/#{count.fdiv(@hits).round(4)} need #{@target_probabilities[name]}"
        }
        out << "]"
    end

    def inspect; to_s end
end

class TestTargets < Minitest::Test
    def test_simple
        s = Targets.new(5, 1e-2, "a" => 2.0/5, "b" => 2.0/5, "c" => 1.0/5)
        2.times {s.record("a")}
        2.times {s.record("b")}
        refute s.satisfied?
        1.times {s.record("c")}
        assert s.satisfied?
    end
    def test_external_hash
        targets = {"a" => 1}
        s = Targets.new(1, 1e-2, targets)
        s.record("a")
        assert s.satisfied?
    end
    def test_zero
        s = Targets.new(1, 1e-2, "a" => 0, "b" => 0)
        assert_raises RuntimeError do
            s.record("a")
        end
        refute s.satisfied?
    end
    def test_unknown_bucket
        s = Targets.new(1, 1e-2, "a" => 1)
        assert_raises ArgumentError do
            s.record("b")
        end
        refute s.satisfied?
    end
    def test_minimum_hits
        s = Targets.new(10, 1e-2, "a" => 1.0, "b" => 0)
        refute s.satisfied?
        9.times { s.record("a") }
        refute s.satisfied?
        s.record("a")
        assert s.satisfied?
    end
end

class TestAdservice < Minitest::Test
    @@PRECISION_TRESHOLD = 0.02
    @@MINIMUM_HITS = 20
    @@REQUESTS_LIMIT = 5000

    [
        {label: "z1", publisher: "9251467", zone: "5694015", targets: {
            "https://integros.com/test/b1" => 0.10,
            "https://integros.com/test/b2" => 0.40,
            "https://integros.com/test/b3" => 0.25,
            "https://integros.com/test/b4" => 0.25}},
        {label: "z2_desktop", publisher: "9251467", zone: "5694016", platform: :desktop, targets: {
            "https://integros.com/test/b1" => 1,
            "https://integros.com/test/b2" => 0,
            "https://integros.com/test/b3" => 0,
            "https://integros.com/test/b4" => 0}},
        {label: "z2_mobile", publisher: "9251467", zone: "5694016", platform: :mobile, targets: {
            "https://integros.com/test/b1" => 0,
            "https://integros.com/test/b2" => 0.20,
            "https://integros.com/test/b3" => 0.40,
            "https://integros.com/test/b4" => 0.40}},
    ].each do |ctx|
        define_method "test_#{ctx[:label]}" do
            api = make_api
            headers = switch_platform!(Hash.new(), ctx[:platform])

            vast_url = api.zone_link(ctx[:publisher], ctx[:zone])
            targets = Targets.new(@@MINIMUM_HITS, @@PRECISION_TRESHOLD, ctx[:targets])

            until targets.satisfied?
                raise "Targets are not satisfied in #{@@REQUESTS_LIMIT} hits. #{targets}" if targets.hits > @@REQUESTS_LIMIT

                xml = open(vast_url, headers).read
                doc = Nokogiri.XML(xml)
                banner_id = doc.search('ClickThrough').text.strip
                targets.record(banner_id)

                p targets
            end
        end
    end

    def make_api()
        api_url = ENV['API_URL'] || 'https://api.integros.io'
        api_key = ENV['API_KEY']
        API.new(api_url, api_key)
    end

    def switch_platform!(headers, platform)
        case platform
        when nil
            headers.delete("User-Agent")
        when :desktop
            headers["User-Agent"] = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/42.0.2311.135 Safari/537.36 Edge/12.246"
        when :mobile
            headers["User-Agent"] = "Mozilla/5.0 (Android 9; Mobile; rv:65.0) Gecko/65.0 Firefox/65.0"
        else
            raise ArgumentError, "Platform could be :desktop or :mobile, got #{platform}"
        end
        headers
    end
end
