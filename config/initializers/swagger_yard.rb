# config/initializers/swagger_yard.rb
SwaggerYard.configure do |config|
  config.swagger_version = "2.0"
  config.title = "ManageIQ API"
  config.description = "Manage your virtual and cloud infrastructure with this opensource API from http://www.manageiq.org"
  config.api_version = "3.0"
  config.api_base_path = "http://localhost:3000/api"
  config.controller_path = '/Users/madhukanoor/devsrc/manageiq-api/app/controllers/**/*'
  #config.controller_path = '/tmp/swagger_yard/spec/fixtures/dummy/app/controllers/**/*'
  config.model_path = '/Users/madhukanoor/devsrc/manageiq/app/models/**/*'
  config.security_definitions['basic_http_auth'] = {
        type: "basic",
        description: "Basic userid/password authentication",
        flow: :implicit
  }
end
