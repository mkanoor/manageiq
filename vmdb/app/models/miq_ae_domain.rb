class MiqAeDomain < MiqAeNamespace
  expose_columns :parent_id, :system, :enabled, :priority
  expose_columns :description, :display_name, :name
  expose_columns :id, :created_on, :updated_on, :updated_by, :created_by_user_id

  validate      :uniqueness_of_domain_name, :on => :create
  validates_inclusion_of :parent_id, :in => [nil]

  def uniqueness_of_domain_name
    errors.add(:name, "domain name #{name} is already in use") unless self.class.find_by_fqname(name).nil?
  end

  def self.enabled
    all_domains.select { |d| d.enabled }
  end

  def self.highest_priority
    all_domains.max_by { |d| d.priority }.try(:priority).to_i
  end

  def self.reset_priority_by_ordered_ids(ids)
    ids.each_with_index do |id, priority|
      find(id).try(:update_attributes, :priority => priority + 1)
    end
  end

  def self.squeeze_priorities
    ids = all_domains.select { |d| d.priority > 0 }.collect(&:id)
    reset_priority_by_ordered_ids(ids)
  end

  def save
    context = persisted? ? :update : :create
    return false unless valid?(context)
    generate_id   unless id
    self.priority  = self.class.highest_priority + 1 unless priority
    hash = setup_envelope(DOMAIN_OBJ_TYPE)
    write_data(name, 'filename' => DOMAIN_YAML_FILE, 'data' => hash.to_yaml)
    true
  end

  def self.fqname_to_filename(fqname)
    "#{fqname}/#{DOMAIN_YAML_FILE}"
  end

  def generate_id
    self.id = self.class.fqname_to_id(name)
  end

  def destroy
    self.class.delete_directory(self.class.fs_name(fqname))
    self.class.squeeze_priorities
    self
  end

  def self.destroy(id)
    obj = MiqAeDomain.find(id)
    obj.destroy if obj
  end

  def self.all_unlocked
    all_domains.reverse.select { |d| d.system.nil? || !d.system }
  end

  def self.any_unlocked?
    all_domains.any? { |d| d.system.nil? || !d.system }
  end

  def self.all_domains
    fetch_domains.sort { |a, b| a.priority <=> b.priority }
  end

  def self.fetch_domains
    sub_dom_dirs  = child_directories(base_dir, MiqAeFsStore::DOMAIN_YAML_FILE, ['*'])
    domain_list = []
    sub_dom_dirs.each do |dir|
      filename = File.join(base_dir, dir, MiqAeFsStore::DOMAIN_YAML_FILE)
      domain_list << find(dir) if File.exist?(filename)
    end
    domain_list
  end

  def self.find_by_name(name)
    find_by_fqname(name)
  end

  def self.order(string)
    parts = string.split(' ')
    attr  = parts[0].downcase
    order = parts[1].downcase
    if order == "asc"
      return fetch_domains.sort { |a, b| a.send(attr) <=> b.send(attr) }
    else
      return fetch_domains.sort { |b, a| a.send(attr) <=> b.send(attr) }
    end
  end
end
