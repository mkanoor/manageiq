class MiqAeNamespace
  include MiqAeModelBase
  include MiqAeFsStore

  expose_columns :system, :enabled, :parent_id, :priority
  expose_columns :description, :display_name, :name
  expose_columns :id, :created_on, :created_by_user_id
  expose_columns :updated_on, :updated_by, :updated_by_user_id
  expose_columns :parent

  validate :uniqueness_of_name, :on => :create

  CLASS_HM_RELATIONS = {:class_name => "MiqAeClass", :foreign_key => :namespace_id, :belongs_to => "ae_namespace"}
  NAMESPACE_HM_RELATIONS = {:class_name => "MiqAeNamespace", :foreign_key => :parent_id, :belongs_to => "ae_namespace"}

  NS_YAML_FILES = [DOMAIN_YAML_FILE, NAMESPACE_YAML_FILE]
  def self.base_class
    MiqAeNamespace
  end

  def self.base_model
    MiqAeNamespace
  end

  def initialize(options = {})
    @attributes = HashWithIndifferentAccess.new(options)
    self.ae_namespace = @attributes.delete(:ae_namespace) if @attributes.key?(:ae_namespace)
  end

  def save
    context = persisted? ? :update : :create
    return false unless valid?(context)
    generate_id   unless id
    fname   = domain? ? DOMAIN_YAML_FILE : NAMESPACE_YAML_FILE
    objtype = domain? ? DOMAIN_OBJ_TYPE : NAMESPACE_OBJ_TYPE
    hash = setup_envelope(objtype)
    write_data(fqname, 'filename' => fname, 'data' => hash.to_yaml)
    true
  end

  def destroy
    self.class.delete_directory(self.class.fs_name(fqname))
    self
  end

  def self.destroy(id)
    obj = MiqAeNamespace.find(id)
    obj.destroy if obj
  end

  def generate_id
    self.id = self.class.fqname_to_id(fqname)
  end

  def self.find_by_fqname(fqname, _include_classes = true)
    return nil if fqname.blank?
    fetch_ns_object(fqname)
  end

  def self.find_by_name(name)
    find_by_fqname(name)
  end

  def self.find_or_create_by_fqname(fqname, include_classes = true)
    return nil if fqname.blank?

    fqname = fqname[1..-1] if fqname[0] == '/'
    found  = find_by_fqname(fqname, include_classes)
    found.nil? ? create_sub_ns(fqname) : found
  end

  def self.create_sub_ns(fqname)
    parent = nil
    parts  = fqname.split('/')
    fqname = ""
    parts.each do |p|
      fqname = "#{fqname}/#{p}"
      found = find_by_fqname(fqname, false)
      if found
        parent = found
      else
        parent = create(:name => p, :parent_id => parent.nil? ? nil : parent.id)
      end
    end
    parent
  end

  def parent
    parent_id ? self.class.find(parent_id) : nil
  end

  def system?
    system
  end

  def enabled?
    enabled
  end

  def ancestors
    node, nodes = self, []
    nodes << node = node.parent while node.parent
    nodes
  end

  def fqname
    @fqname ||= "/#{ancestors.collect(&:name).reverse.push(name).join('/')}"
  end

  def editable?
    return !system? if domain?
    return false if ancestors.any?(&:system?)
    !system?
  end

  def ns_fqname
    return nil if fqname == domain_name
    fqname.sub(domain_name.to_s, '')
  end

  def fqname_sans_domain
    fqname.split('/')[1..-1].join("/")
  end

  def domain_name
    domain.try(:name)
  end

  def domain
    if domain?
      self
    elsif (ns = ancestors.last) && ns.domain?
      ns
    end
  end

  def domain?
    parent_id.nil? && name != '$'
  end

  def ae_namespaces
    @ns_proxy ||= MiqAeHasManyProxy.new(self, NAMESPACE_HM_RELATIONS, load_child_namespaces)
  end

  def ae_classes
    @class_proxy ||= MiqAeHasManyProxy.new(self, CLASS_HM_RELATIONS, load_classes)
  end

  def load_child_namespaces(ns_filters = ['*'])
    load_namespace_children(MiqAeNamespace, NAMESPACE_YAML_FILE, ns_filters)
  end

  def load_classes(class_filters = ['*'])
    load_namespace_children(MiqAeClass, CLASS_YAML_FILE, class_filters)
  end

  def self.filename_to_fqname(filename)
    rel_path = relative_path(filename)
    File.dirname(rel_path)
  end

  def self.find(id)
    return nil unless id
    find_by_fqname(id_to_fqname(id))
  end

  def self.find_by_id(id)
    find(id)
  end

  def self.fqname_to_filename(fqname)
    file_name = ns_file_name(fqname)
    relative_path(file_name) if file_name
  end

  def self.fetch_ns_object(fqname)
    file_name = ns_file_name(fqname)
    load_file(file_name) if file_name
  end

  def self.ns_file_name(fqname)
    base_dir = fs_name(fqname)
    return nil unless base_dir
    fname = NS_YAML_FILES.detect { |f| File.exist?(File.join(base_dir, f)) }
    raise "Error cannot convert #{fqname} to filename" unless fname
    File.join(base_dir, fname)
  end

  def self.all(_find_options = {})
    MiqAeDomain.all_domains
  end

  def self.find_tree(find_options = {})
    namespaces = all(find_options)
    ns_lookup = namespaces.inject({}) do |h, ns|
      h[ns.id] = ns
      h
    end

    roots = []

    # Rails3 TODO: Review how we are doing this in light of changes to Associations
    # Assure all of the ae_namespaces reflections are loaded to prevent re-queries
    namespaces.each { |ns| ns.ae_namespaces }

    namespaces.each do |ns|
      if ns.parent_id.nil?
        roots << ns
      else
        # Manually fill in the ae_namespaces reflections of the parents
        parent = ns_lookup[ns.parent_id]
        parent.ae_namespaces.target.push(ns) unless parent.nil?
      end
    end
    roots
  end

  def load_children
    load_child_namespaces
  end

  def children
    load_child_namespaces
  end

  # returns all siblings of the current node.
  #
  #   subchild1.siblings # => [subchild2]
  def siblings
    self_and_siblings - [self]
  end

  # Returns all siblings and a reference to the current node.
  #
  #   subchild1.self_and_siblings # => [subchild1, subchild2]
  def self_and_siblings
    parent ? parent.children : self.class.roots
  end
end
