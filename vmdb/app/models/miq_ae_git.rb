require 'rugged'

class MiqAeGit
  attr_accessor :name, :email
  ENTRY_KEYS = [:path, :dev, :ino, :mode, :gid, :uid, :ctime, :mtime]
  DEFAULT_FILE_MODE = 0100644
  LOCK_REFERENCE = 'refs/locks'

  def initialize(options = {})
    raise ArgumentError, "Must specify path" unless options.key?(:path)
    @path       = options[:path]
    @email      = options[:email]
    @name       = options[:name]
    @bare       = options[:bare]
    @commit_sha = options[:commit_sha]
    @base_name  = File.basename(@path).downcase
    options[:new] ? create_repo : open_repo
  end

  def create_repo
    @repo = @bare ? Rugged::Repository.init_at(@path, :bare) :
                    Rugged::Repository.init_at(@path)
    @repo.config['core.ignorecase'] = true
  end

  def open_repo
    @repo = Rugged::Repository.new(@path)
  end

  def delete_repo
    return false unless @repo
    @repo.close
    FileUtils.rm_rf(@path)
    true
  end

  def add(hash, commit_sha = nil)
    raise ArgumentError, "Must specify path" unless hash.key?(:path)
    raise ArgumentError, "Must specify data" unless hash.key?(:data)
    entry = {}
    ENTRY_KEYS.each { |key| entry[key] = hash[key] if hash.key?(key) }
    entry[:oid] = @repo.write(hash[:data], :blob)
    entry[:mode] ||= DEFAULT_FILE_MODE
    entry[:mtime] ||= Time.now
    current_index(commit_sha).add(entry)
  end

  def remove(path, commit_sha = nil)
    current_index(commit_sha).remove(path)
  end

  def remove_dir(path, commit_sha = nil)
    current_index(commit_sha).remove_dir(path)
  end

  def file_exists?(path, commit_sha = nil)
    find_entry(path, commit_sha) ? true : false
  end

  def directory_exists?(path, commit_sha = nil)
    entry = find_entry(path, commit_sha)
    entry ? entry[:type] == :tree : false
  end

  def read_file(path, commit_sha = nil)
    entry = find_entry(path, commit_sha)
    raise MiqException::MiqGitEntryMissing, path unless entry
    @repo.lookup(entry[:oid]).content
  end

  def read_entry(entry)
    @repo.lookup(entry[:oid]).content
  end

  def directory?(path, commit_sha = nil)
    entry = find_entry(path, commit_sha)
    raise MiqException::MiqGitEntryMissing, path unless entry
    entry[:type] == :tree
  end

  def entries(path, commit_sha = nil)
    tree = path.empty? ? lookup_commit_tree : get_tree(path)
    tree.find_all.collect { |e| e[:name] }
  end

  def nodes(path, commit_sha = nil)
    tree = path.empty? ? lookup_commit_tree : get_tree(path)
    entries = tree.find_all
    entries.each do |entry|
      entry[:full_name] = File.join(@base_name, path, entry[:name])
      entry[:rel_path] = File.join(path, entry[:name])
    end
  end

  def commit(message, ff = true)
    tree = @current_index.write_tree(@repo)
    parents = @repo.empty? ? [] : [@repo.head.target].compact
    create_commit(message, tree, parents).tap do |c|
      fast_forward_commit(c) if ff
    end
  end

  def file_attributes(fname)
    walker = Rugged::Walker.new(@repo)
    walker.sorting(Rugged::SORT_DATE)
    walker.push(@repo.head.target)
    commit = walker.find  { |c| c.diff(:paths => [fname]).size > 0 }
    return {} unless commit
    {:updated_on => commit.time.gmtime, :updated_by => commit.author[:name]}
  end

  def fast_forward_commit(commit)
    lock do
      merge_index = @repo.branches['master'] ?
                    @repo.merge_commits(@repo.branches['master'].target, commit) : nil
      if merge_index && merge_index.conflicts?
        result = differences_with_master(commit)
        raise MiqException::MiqGitConflicts, result
      end
      @repo.reset(commit, :soft)
    end
  end

  def file_list(commit_sha = nil)
    tree = lookup_commit_tree(commit_sha || @commit_sha)
    return [] unless tree
    tree.walk(:preorder).collect { |root, entry| "#{root}#{entry[:name]}" }
  end

  def find_entry(path, commit_sha = nil)
    get_tree_entry(path.downcase, commit_sha)
  end

  def list_files(commit_sha = nil)
    tree = lookup_commit_tree(commit_sha || @commit_sha)
    return [] unless tree
    tree.walk(:preorder).collect { |r, e| File.join(r, e[:name]) }
  end

  def mv_file_with_new_contents(old_file, new_hash, commit_sha = nil)
    add(new_hash, commit_sha)
    remove(old_file, commit_sha)
  end

  def mv_file(old_file, new_file, commit_sha = nil)
    entry = current_index[old_file]
    return unless entry
    entry[:path] = new_file
    current_index(commit_sha).add(entry)
    remove(old_file, commit_sha)
  end

  def mv_dir(old_dir, new_dir, commit_sha = nil)
    old_dir = fix_path_mv(old_dir)
    new_dir = fix_path_mv(new_dir)
    updates = current_index(commit_sha).entries.select { |entry| entry[:path].start_with?(old_dir) }
    updates.each do |entry|
      entry[:path] = entry[:path].gsub(old_dir, new_dir)
      current_index(commit_sha).add(entry)
    end
    current_index(commit_sha).remove_dir(old_dir)
  end

  private

  def fix_path_mv(dir_name)
    dir_name = dir_name[1..-1] if dir_name[0] == '/'
    dir_name += '/'            if dir_name[-1] != '/'
    dir_name
  end

  def filename(path, commit_sha = nil)
    entry = get_tree_entry(path, commit_sha)
    entry ? entry[:full_name] : nil
  end

  def get_tree(path, commit_sha = nil)
    entry = get_tree_entry(path, commit_sha)
    raise MiqException::MiqGitEntryMissing, path unless entry
    raise MiqException::MiqGitEntryNotADirectory, path  unless entry[:type] == :tree
    @repo.lookup(entry[:oid])
  end

  def lookup_commit_tree(commit_sha = nil)
    return nil unless @repo.branches['master']
    ct = commit_sha ? @repo.lookup(commit_sha) : @repo.branches['master'].target
    ct.tree if ct
  end

  def get_tree_entry(path, commit_sha = nil)
    path = path[1..-1] if path[0] == '/'
    tree = lookup_commit_tree(commit_sha || @commit_sha)
    begin
      entry = tree.path(path)
      entry[:full_name] = File.join(@base_name, path)
      entry[:rel_path] = path
    rescue
      return nil
    end
    entry
  end

  def old_tree_entry(path, commit_sha = nil)
    tree = lookup_commit_tree(commit_sha || @commit_sha)
    return nil unless tree
    path = path[1..-1] if path[0] == '/'
    full_name = append_domain ? @base_name : nil
    entry = nil
    path.split('/').each do |seg|
      entry = tree.entries.detect { |f| f[:name].casecmp(seg) == 0 }
      break unless entry
      full_name = full_name ? File.join(full_name, entry[:name]) : entry[:name]
      tree = @repo.lookup(entry[:oid]) if entry[:type] == :tree
    end
    entry[:full_name] = full_name if entry
    entry
  end

  def current_index(commit_sha = nil)
    @current_index ||= Rugged::Index.new.tap do |index|
      unless @repo.empty?
        tree = @repo.branches['master'].target.tree
        @current_tree_oid = tree.oid
        index.read_tree(tree)
      end
    end
  end

  def create_commit(message, tree, parents)
    author = {:email => @email, :name => @name, :time => Time.now}
    # Create the actual commit but dont update the reference
    Rugged::Commit.create(@repo, :author  => author,  :committer  => author,
                                 :message => message, :parents    => parents,
                                 :tree    => tree)
  end

  def lock
    @repo.references.create(LOCK_REFERENCE, 'refs/heads/master')
    yield
    rescue Rugged::ReferenceError
      sleep 0.1
      retry
    ensure
      @repo.references.delete(LOCK_REFERENCE)
  end

  def branch
    @branch ||= @repo.create_branch(SecureRandom.uuid)
  end

  def differences_with_master(commit)
    differences = {}
    diffs = @repo.diff(commit, @repo.head.target)
    diffs.deltas.each do |delta|
      result = []
      delta.diff.each_line do |line|
        next unless line.addition? || line.deletion?
        result << "+ #{line.content.to_str}"  if line.addition?
        result << "- #{line.content.to_str}"  if line.deletion?
      end
      differences[delta.old_file[:path]] = {:status => delta.status, :diffs => result}
    end
    differences
  end
end
