require 'miq-syntax-checker'

class MiqAeMethod
  include MiqAeModelBase
  include MiqAeFsStore
  expose_columns :class_id, :data, :language, :location, :scope
  expose_columns :description, :display_name, :name
  expose_columns :id, :created_on, :created_by_user_id
  expose_columns :updated_on, :updated_by, :updated_by_user_id
  NEW_LINE = "\n"

  METHOD_ATTRIBUTES = %w(scope language location)

  AVAILABLE_LANGUAGES  = %w(ruby perl)
  validates_inclusion_of :language,  :in => AVAILABLE_LANGUAGES
  AVAILABLE_LOCATIONS  = %w(builtin inline uri)
  validates_inclusion_of :location,  :in => AVAILABLE_LOCATIONS
  AVAILABLE_SCOPES     = %w(class instance)
  validates_inclusion_of :scope,     :in => AVAILABLE_SCOPES

  validates_presence_of :class_id
  validate :uniqueness_of_name, :on => :create

  INPUT_HM_RELATIONS  = {:class_name => "MiqAeField", :foreign_key => :method_id,
                         :belongs_to => 'ae_method', :save_parent => true}

  def self.column_names
    %w(class_id data language location scope
       description display_name name id
       created_on created_by_user_id updated_on updated_by
       updated_by_user_id)
  end

  def self.base_class
    MiqAeMethod
  end

  def self.base_model
    MiqAeMethod
  end

  def initialize(options = {})
    @attributes   = HashWithIndifferentAccess.new(options)
    self.inputs   = @attributes.delete(:inputs) if @attributes.key?(:inputs)
    self.ae_class = @attributes.delete(:ae_class) if @attributes.key?(:ae_class)
  end

  def self.new_with_hash(options = {})
    new(options)
  end

  def inputs
    @inputs_proxy ||= MiqAeHasManyProxy.new(self, INPUT_HM_RELATIONS)
  end

  def inputs=(*obj)
    @inputs_proxy = MiqAeHasManyProxy.new(self, INPUT_HM_RELATIONS)
    @inputs_proxy.assign(obj)
  end

  def add_relations(yaml_hash)
    @inputs_proxy    = MiqAeHasManyProxy.new(self, INPUT_HM_RELATIONS, load_all_fields(yaml_hash))
  end

  def ae_class
    @ae_class ||= MiqAeClass.find(@class_id)
  end

  def ae_class=(obj)
    @ae_class = obj
    @attributes[:class_id]  = obj.id
  end

  def load_all_fields(yaml_hash)
    result = []
    yaml_hash['object']['inputs'].each do |f|
      field_id = "#{id}##{f['field']['name'].downcase}"
      hash = {:method_id => id, :id => "#{field_id}"}
      result << ::MiqAeField.new(hash.merge(f['field']))
    end
    result
  end

  def changed?
    new_record? || changes.keys.present? || inputs_changed?
  end

  def self.find(id)
    return nil if id.blank?
    return hack_for_first_method if id == :first
    find_by_fqname(id_to_fqname(id))
  end

  def self.hack_for_first_method
    MiqAeDomain.all[0].ae_namespaces[0].ae_classes[0].ae_methods[0]
  end

  def self.find_by_fqname(fqname)
    return nil if fqname.blank?
    filename = fqname_to_filename(fqname)
    find_by_filename(filename)
  end

  def self.find_by_filename(filename)
    filename = fs_name(filename)
    return nil unless filename
    yaml_hash = load_yaml_file(filename)
    location = yaml_hash['object']['attributes']['location']
    language = yaml_hash['object']['attributes']['language']
    data = load_method_file(filename, location, language)
    yaml_hash['object']['attributes']['data'] = data
    obj = load_file(filename, yaml_hash)
    obj.add_relations(yaml_hash)
    obj
  end

  def self.find_by_id(id)
    find(id)
  end

  def self.find_by_name_and_class_id(name, class_id)
    fq_name = "#{MiqAeClass.id_to_fqname(class_id)}/#{name}"
    find_by_fqname(fq_name)
  end

  def self.fqname_to_filename(fqname)
    domain, nsd, klass, meth = ::MiqAeEngine::MiqAePath.get_domain_ns_klass_inst(fqname)
    dirname = METHODS_DIRECTORY
    dirname = "#{dirname}/#{CLASS_SCOPE_PREFIX}" if meth.start_with?(CLASS_SCOPE_PREFIX)
    meth = meth.split(CLASS_SCOPE_PREFIX)[-1]
    return "#{domain}/#{klass}#{CLASS_DIR_SUFFIX}/#{dirname}/#{meth}.yaml" if nsd.blank?
    "#{domain}/#{nsd}/#{klass}#{CLASS_DIR_SUFFIX}/#{dirname}/#{meth}.yaml"
  end

  def self.available_languages
    AVAILABLE_LANGUAGES
  end

  def self.available_locations
    AVAILABLE_LOCATIONS
  end

  def self.available_scopes
    AVAILABLE_SCOPES
  end

  def ae_class
    return nil unless class_id
    @ae_class ||= MiqAeClass.find(class_id)
  end

  def generate_id
    self.id = self.class.fqname_to_id(fqname)
    self.class_id ||= self.class.fqname_to_id(ae_class.fqname)
  end

  def save
    context = persisted? ? :update : :create
    return false unless valid?(context)
    generate_id  unless id
    return false unless auto_save_inputs
    write
  end

  def write
    hash = setup_envelope(METHOD_OBJ_TYPE)
    hash['object']['inputs'] = method_inputs
    sub_dir = "#{ae_class.fqname}#{CLASS_DIR_SUFFIX}/#{METHODS_DIRECTORY}"
    sub_dir = "#{sub_dir}/#{CLASS_SCOPE_PREFIX}" if scope == 'class'
    write_data(sub_dir, 'filename' => "#{name}.yaml", 'data' => hash.to_yaml)
    write_method(sub_dir) if location == "inline" && data.present?
    true
  end

  def auto_save_inputs
    inputs.each do |f|
      f.ae_method = self
      errors.add(:inputs, f.errors.full_messages.join(' ')) unless f.auto_save
    end
    errors.empty?
  end

  def inputs_changed?
    inputs.any? { |i| i.changes.keys.present? }
  end

  def destroy
    delete_method_file
    filename = self.class.fs_name(self.class.fqname_to_filename(fqname))
    self.class.delete_file(filename) if filename
  end

  def write_method(sub_dir)
    self.data += NEW_LINE unless data.end_with?(NEW_LINE)
    hash = {'filename' => self.class.method_file_name("#{name}.yaml", location, language), 'data' => data}
    write_data(sub_dir, hash)
  end

  # Validate the syntax of the passed in inline ruby code
  def self.validate_syntax(code_text)
    result = MiqSyntaxChecker.check(code_text)
    return nil if result.valid?
    # Array of arrays for future multi-line support
    [[result.error_line, result.error_text]]
  end

  def fqname
    scope == "class" ? "#{ae_class.fqname}/#{CLASS_SCOPE_PREFIX}#{name}" : "#{ae_class.fqname}/#{name}"
  end

  def self.filename_to_fqname(filename)
    rel_path = relative_path(filename)
    meth = File.basename(rel_path, '.yaml')
    if File.basename(File.dirname(rel_path)) == CLASS_SCOPE_PREFIX
      meth = "#{CLASS_SCOPE_PREFIX}#{meth}"
      parent_dir = File.dirname(File.dirname(rel_path))
    else
      parent_dir = File.dirname(rel_path)
    end
    class_dir = File.dirname(parent_dir)
    class_dir = class_dir.gsub(CLASS_DIR_SUFFIX, "")
    "#{class_dir}/#{meth}"
  end

  def domain
    ae_class.domain
  end

  def self.default_method_text
    <<-DEFAULT_METHOD_TEXT
  #
  # Description: <Method description here>
  #
    DEFAULT_METHOD_TEXT
  end

  def to_export_yaml
    export_attributes
  end

  def method_inputs
    inputs.collect(&:to_export_yaml)
  end

  def to_export_xml(options = {})
    require 'builder'
    xml = options[:builder] ||= ::Builder::XmlMarkup.new(:indent => options[:indent])
    xml_attrs = {:name => name, :language => language, :scope => scope, :location => location}

    self.class.column_names.each do |cname|
      # Remove any columns that we do not want to export
      next if %w(id created_on updated_on updated_by).include?(cname) || cname.ends_with?("_id")

      # Skip any columns that we process explicitly
      next if %w(name language scope location data).include?(cname)

      # Process the column
      xml_attrs[cname.to_sym]  = send(cname)   unless send(cname).blank?
    end

    xml.MiqAeMethod(xml_attrs) do
      xml.target!.chomp!
      xml << "<![CDATA[#{data}]]>"
      inputs.each { |i| i.to_export_xml(:builder => xml) }
    end
  end

  def editable?
    ae_class.ae_namespace.editable?
  end

  def field_names
    inputs.collect { |f| f.name.downcase }
  end

  def field_value_hash(name)
    field = inputs.detect { |f| f.name.casecmp(name) == 0 }
    raise "Field #{name} not found in method #{self.name}" if field.nil?
    field.attributes
  end

  def self.copy(options)
    if options[:new_name]
      MiqAeMethodCopy.new(options[:fqname]).as(options[:new_name],
                                               options[:namespace],
                                               options[:overwrite_location])
    else
      MiqAeMethodCopy.copy_multiple(options[:ids],
                                    options[:domain],
                                    options[:namespace],
                                    options[:overwrite_location])
    end
  end

  def self.get_homonymic_across_domains(fqname, enabled = nil)
    MiqAeDatastore.get_homonymic_across_domains(::MiqAeMethod, fqname, enabled)
  end

  def self.find_by_class_id_and_name(class_id, name)
    cls_obj = MiqAeClass.find(class_id)
    return nil unless cls_obj
    cls_obj.ae_methods.detect { |m| m.name.casecmp(name) == 0 }
  end

  def load_children
    inputs
  end
end
