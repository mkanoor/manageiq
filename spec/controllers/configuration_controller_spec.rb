describe ConfigurationController do
  [[0, "12AM-1AM"],
   [7, "7AM-8AM"],
   [11, "11AM-12PM"],
   [18, "6PM-7PM"],
   [19, "7PM-8PM"],
   [23, "11PM-12AM"]].each do |io|
    context ".get_hr_str" do
      it "should return interval for #{io[0]} o'clock: #{io[1]}" do
        interval = controller.get_hr_str(io[0])
        expect(interval).to eql(io[1])
      end
    end
  end

  context "#timeprofile_get_form_vars" do
    before do
      timeprofile = FactoryGirl.create(:time_profile)
      @request.session = {:edit => {:new         => {:profile_type => 'Not a user'},
                                    :userid      => 1234,
                                    :timeprofile_id => timeprofile.id}}
    end
    it 'sets @timeprofile' do
      controller.send(:timeprofile_get_form_vars)
      expect(controller.instance_variable_get(:@timeprofile)).to be_a_kind_of(TimeProfile)
    end
  end

  describe "building tabs" do
    before(:each) do
      controller.instance_variable_set(:@tabform, "ui_2")
      controller.instance_variable_set(:@config_tab, "ui")
    end

    it 'sets the active tab' do
      controller.send(:build_tabs)
      expect(assigns(:active_tab)).to eq("2")
    end

    it 'sets the available tabs' do
      allow(controller).to receive(:role_allows).and_return(true)
      controller.send(:build_tabs)

      expect(assigns(:tabs)).to eq([
        ["1", _("Visual")],
        ["2", _("Default Views")],
        ["3", _("Default Filters")],
        ["4", _("Time Profiles")]
      ])
    end
  end
end
