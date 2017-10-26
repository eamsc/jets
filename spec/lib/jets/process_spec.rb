require_relative "../../spec_helper"

describe Jets::Process do
  before(:all) do
    # @args = "--noop --project-root spec/fixtures/my_project"
    @args = '\'{ "we" : "love", "using" : "Lambda" }\' \'{"test": "1"}\' "handlers/controllers/posts.create"'
  end

  describe "jets process" do
    it "controller [event] [context] [handler]" do
      out = execute("bin/jets process controller #{@args}")
      # pp out # uncomment to debug
      data = JSON.parse(out)
      expect(data["statusCode"]).to eq 200
      expect(data["body"]).to eq({"we"=>"love", "using"=>"Lambda","a"=>"create"})
    end
  end
end