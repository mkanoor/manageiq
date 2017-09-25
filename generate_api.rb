require 'swagger_yard'
SwaggerYard.register_custom_yard_tags!
File.open("manageiq_api.json", "w") do |f|
      f.puts JSON.pretty_generate(SwaggerYard::Swagger.new.to_h)
end
