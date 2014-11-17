require 'spec_helper.rb'

describe MiqAeGit do
  context "case insensitive filenames" do
    before do
      git_db    = "TestGit.git"
      ae_db_dir = Dir.mktmpdir
      @default_hash = {:a => "one", :b => "two", :c => "three"}
      @filenames = %w(a/file1.yaml b/file2.yaml c/file3.yaml)
      @dirnames  = %w(a b c)
      @dirnames_mixed  = %w(A B C)
      @repo_path   = File.join(ae_db_dir, git_db)
      @mixed_names = %w(A/File1.YamL B/File2.YamL c/File3.YAML)
      @deleted_names = %w(a a/file1.yaml)
      @conflict_file = 'a/file1.yaml'
      options = {:path  => @repo_path,
                 :name  => "user1",
                 :email => "user1@example.com",
                 :bare  => true,
                 :new   => true}
      @ae_db = MiqAeGit.new(options)
      @original_commit = add_files_to_bare_repo(@filenames)
    end

    def add_files_to_bare_repo(flist)
      flist.each do |f|
        @ae_db.add(:path => f, :data => YAML.dump(@default_hash.merge(:fname => f)))
      end
      @ae_db.commit("files_added")
    end

    def open_existing_repo
      options = {:path  => @repo_path,
                 :name  => "user1",
                 :email => "user1@example.com"}
      MiqAeGit.new(options)
    end

    it "get list of files" do
      @ae_db.file_list.should match_array(@filenames + @dirnames)
    end

    it "rename directory" do
      filenames = %w(AAA/file1.yaml b/file2.yaml c/file3.yaml)
      dirnames  = %w(AAA b c)
      @ae_db.mv_dir('a', "AAA")
      @ae_db.commit("directories moved")
      @ae_db.file_list.should match_array(filenames + dirnames)
    end

    it "get list of files from a specific commit" do
      @ae_db.remove_dir("a")
      @ae_db.commit("directories deleted")
      @ae_db.file_list.should match_array(@filenames + @dirnames - @deleted_names)
      @ae_db.file_list(@original_commit).should match_array(@filenames + @dirnames)
    end

    it "can delete directories" do
      @dirnames.each { |d| @ae_db.remove_dir(d) }
      @ae_db.commit("directories deleted")
      @mixed_names.each  { |f| @ae_db.file_exists?(f).should be_false }
    end

    it "rename file with new contents" do
      filenames = %w(a/file11.yaml b/file2.yaml c/file3.yaml)
      @ae_db.mv_file_with_new_contents('a/file1.yaml', :path => 'a/file11.yaml', :data => "Hello")
      @ae_db.commit("file renamed")
      @ae_db.file_list.should match_array(filenames + @dirnames)
    end

    it "rename file" do
      filenames = %w(a/file11.yaml b/file2.yaml c/file3.yaml)
      @ae_db.mv_file('a/file1.yaml', 'a/file11.yaml')
      @ae_db.commit("file renamed")
      @ae_db.file_list.should match_array(filenames + @dirnames)
    end

    it "manage conflicts" do
        @ae_db.add(:path => @conflict_file, :data => YAML.dump(@default_hash.merge(:fname => "first_one")))
        commit = @ae_db.commit("suspended commit", false)

        new_db = open_existing_repo
        new_db.add(:path => @conflict_file, :data => YAML.dump(@default_hash.merge(:fname => "second_one")))
        new_db.commit("overlapping commit")
        expect { @ae_db.fast_forward_commit(commit) }.to raise_error { |error|
          expect(error).to be_a(MiqException::MiqGitConflicts)
        }
    end

  end
end
