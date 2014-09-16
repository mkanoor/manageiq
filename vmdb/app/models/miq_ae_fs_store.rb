module MiqAeFsStore
  DOMAIN_YAML_FILE    = '__domain__.yaml'
  NAMESPACE_YAML_FILE = '__namespace__.yaml'
  CLASS_YAML_FILE     = '__class__.yaml'
  METHODS_DIRECTORY   = '__methods__'
  CLASS_DIR_SUFFIX    = '.class'
  OBJ_YAML_VERSION    = '1.0'
  DOMAIN_OBJ_TYPE     = 'domain'
  NAMESPACE_OBJ_TYPE  = 'namespace'
  CLASS_OBJ_TYPE      = 'class'
  INSTANCE_OBJ_TYPE   = 'instance'
  METHOD_OBJ_TYPE     = 'method'
  CLASS_SCOPE_PREFIX = "$CLASS$"
  BASE_DIR            = MiqAeDatastore::DATASTORE_DIRECTORY.to_s
  BASE_DIR_LENGTH     = BASE_DIR.length

  extend ActiveSupport::Concern

  module ClassMethods
    def exists?(fqname)
      return false if fqname.blank?
      fname = fqname_to_filename(fqname)
      return false unless fname
      fs_name(fname) ? true : false
    end

    def id_to_fqname(id)
      id.class == String ? CGI.unescape(id) : nil
    end

    def fqname_to_id(fqname)
      CGI.escape(fqname)
    end

    def base_dir
      BASE_DIR
    end

    def load_yaml_file(filename)
      YAML.load_file(filename)
    end

    def fs_name(path, create = false)
      path   = path[1..-1] if path[0] == '/'
      full_name = BASE_DIR
      path.split('/').each do |seg|
        fs = Dir.entries(full_name).detect { |f| f.casecmp(seg) == 0 }
        if fs.nil?
          if create
            fs = seg
          else
            return nil
          end
        end
        full_name = File.join(full_name, fs)
      end
      full_name
    end

    def relative_path(path)
      path = File.expand_path(path)
      path[BASE_DIR_LENGTH..-1] if path.start_with?(base_dir)
    end

    def load_method_file(filename, location, language)
      script_file = method_file_name(filename, location, language)
      return "" unless script_file
      File.exist?(script_file) ? File.open(script_file) { |f| f.read } : ""
    end

    def method_file_name(filename, location, language)
      return nil if location.casecmp('builtin') == 0
      return nil if location.casecmp('uri') == 0
      return filename.gsub('.yaml', '.rb') if language.casecmp('ruby') == 0
    end

    def child_directories(parent_dir, yaml_file, filters)
      return [] unless File.directory?(parent_dir)
      Dir.entries(parent_dir).select do |f|
        next if f == "." || f == ".."
        partial_name = f.split('.')[0] if f.ends_with?(CLASS_DIR_SUFFIX)
        name = partial_name || f
        File.exist?(File.join(parent_dir, f, yaml_file)) && item_matches?(name, filters)
      end
    end

    def item_matches?(item, filters)
      filters.any? { |f| File.fnmatch(f, item, File::FNM_CASEFOLD) }
    end

    def delete_directory(full_name)
      return false unless File.directory?(full_name)
      FileUtils.rm_rf(full_name)
    end

    def delete_file(full_name)
      return false unless File.exist?(full_name)
      FileUtils.rm_rf(full_name)
    end

    def merge_class_descendants(filename, attrs)
      parent_dir = File.dirname(filename)
      tail_name = File.basename(parent_dir)

      if tail_name == CLASS_SCOPE_PREFIX
        parent_dir = File.dirname(parent_dir)
        tail_name  = File.basename(parent_dir)
      end

      if tail_name == METHODS_DIRECTORY
        attrs['id'] = fqname_to_id(filename_to_fqname(filename))
        parent_dir = File.dirname(parent_dir)
      else
        attrs['id'] = fqname_to_id(filename_to_fqname(filename))
      end
      attrs['class_id'] = fqname_to_id(MiqAeClass.filename_to_fqname(File.join(parent_dir, CLASS_YAML_FILE)))
    end

    def merge_file_stats(filename, attrs)
      stats = File::Stat.new(filename)
      attrs['created_on'] = stats.ctime.gmtime
      attrs['updated_on'] = stats.mtime.gmtime
    end

    def merge_ids(filename, attrs)
      tail_name = File.basename(filename)
      if tail_name == CLASS_YAML_FILE
        parent_dir = File.dirname(File.dirname(filename))
        attrs['id'] = fqname_to_id(MiqAeClass.filename_to_fqname(filename))
        attrs['namespace_id'] = fqname_to_id(MiqAeNamespace.filename_to_fqname(File.join(parent_dir, NAMESPACE_YAML_FILE)))
      elsif tail_name == NAMESPACE_YAML_FILE
        parent_dir = File.dirname(File.dirname(filename))
        attrs['id'] = fqname_to_id(MiqAeNamespace.filename_to_fqname(filename))
        ns_file = File.join(parent_dir, NAMESPACE_YAML_FILE)
        if File.exist?(ns_file)
          attrs['parent_id'] = fqname_to_id(MiqAeNamespace.filename_to_fqname(ns_file))
        else
          domain_file = File.join(parent_dir, DOMAIN_YAML_FILE)
          attrs['parent_id'] = fqname_to_id(MiqAeNamespace.filename_to_fqname(domain_file)) if File.exist?(domain_file)
        end
      elsif tail_name == DOMAIN_YAML_FILE
        attrs['id'] = fqname_to_id(MiqAeNamespace.filename_to_fqname(filename))
        attrs['parent_id'] = nil
      else
        merge_class_descendants(filename, attrs)
      end
    end

    def load_file(filename = nil, yaml_hash = nil)
      if filename && File.exist?(filename)
        yaml_hash ||= YAML.load_file(filename)
        attrs = yaml_hash['object']['attributes']
        merge_ids(filename, attrs)
        merge_file_stats(filename, attrs)
        new_with_hash(attrs)
      end
    end
  end

  # Instance Methods
  def setup_envelope(obj_type)
    {'object_type' => obj_type,
     'version'     => OBJ_YAML_VERSION,
     'object'      => {'attributes' => export_attributes}}
  end

  def uniqueness_of_name
    errors.add(:name, "#{name} already exists as #{fqname}") if self.class.exists?(fqname)
  end

  def write_data(rel_path, hash)
    fqpath = self.class.fs_name(rel_path, true)
    FileUtils.mkpath(fqpath) unless File.directory?(fqpath)
    fq_filename = File.join(fqpath, hash['filename'].downcase)
    File.write(fq_filename, hash['data'])
  end

  def load_class_children(klass, sub_dir = nil, filter = '*')
    child_dir = sub_dir ? File.join(dirname, sub_dir) : dirname
    result = []
    return [] unless File.exist?(child_dir)
    Dir.entries(child_dir).each do |f|
      next if f == CLASS_YAML_FILE
      next unless File.extname(f) == '.yaml'
      basename = File.basename(f, '.yaml')
      next unless File.fnmatch(filter, basename, File::FNM_CASEFOLD | File::FNM_DOTMATCH)
      fqname = klass.filename_to_fqname(File.join(child_dir, f))
      result << klass.find_by_fqname(fqname)
    end
    result
  end

  def load_class_methods(filter = '*')
    load_class_children(MiqAeMethod, METHODS_DIRECTORY, filter) +
      load_class_children(MiqAeMethod, "#{METHODS_DIRECTORY}/#{CLASS_SCOPE_PREFIX}", filter)
  end

  def convert_hash_to_methods(hash)
    hash.each do |k, v|
      instance_variable_set("@#{k}", v)
      singleton_class.class_eval { attr_accessor "#{k}" }
    end
  end

  def load_namespace_children(klass, base_filename, filters)
    parent_dir = self.class.fs_name(fqname)
    sub_dirs  = self.class.child_directories(parent_dir, base_filename, filters)
    sub_dirs.collect do |dir|
      filename = File.join(parent_dir, dir, base_filename)
      fqname   = klass.filename_to_fqname(filename)
      klass.find(fqname)
    end
  end

  def dirname
    @dirname ||= File.dirname(self.class.fs_name(self.class.fqname_to_filename(fqname)))
  end

  def delete_method_file
    method_file = self.class.method_file_name("#{name}.yaml", location, language)
    if method_file
      method_file = File.join(dirname, method_file)
      self.class.delete_file(method_file)
    end
  end

  def reload
    filename = self.class.fs_name(self.class.fqname_to_filename(fqname))
    raise "#{fqname} doesn't have a valid file" unless filename
    yaml_hash = self.class.load_yaml_file(filename)
    update_attributes(yaml_hash['object']['attributes'])
    refresh_associations(yaml_hash)
    self
  end
end
