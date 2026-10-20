# frozen_string_literal: true

require 'open3'
require 'rbconfig'

# Runs in a child process, so the prepend does not reach the other specs.
RSpec.describe Kiosk::TestHelpers do
  describe 'kiosk/test_helpers/small_equihash' do
    def params_after(code)
      out, status = Open3.capture2e(RbConfig.ruby, '-e', <<~RUBY)
        require 'kiosk/pow/equihash'
        #{code}
        print Kiosk::Pow::Equihash.params.inspect, '|', Kiosk::Pow::Equihash.params(n: 168, k: 7).inspect
      RUBY
      raise out unless status.success?

      out
    end

    it 'leaves the production default alone until it is required' do
      expect(params_after('')).to eq('{n: 168, k: 7}|{n: 168, k: 7}')
    end

    it 'makes the default n=96 k=5 and keeps explicit params' do
      expect(params_after("require 'kiosk/test_helpers/small_equihash'")).to eq('{n: 96, k: 5}|{n: 168, k: 7}')
    end
  end
end
