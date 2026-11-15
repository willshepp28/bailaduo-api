require 'test_helper'

class ProfileTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(email: 'dancer@example.test', password: SecureRandom.hex(16))
    @profile = @user.build_profile(display_name: ' Dancer ', age: 18, city: ' Playa del Carmen ',
      dance_styles: [' Bachata ', 'bachata', ''], experience_level: 'Beginner',
      availability: ' Weekends ', primary_photo_url: 'https://images.example.test/dancer.jpg')
  end

  test 'normalizes required profile data' do
    assert @profile.save
    assert_equal ['bachata'], @profile.dance_styles
    assert_equal 'Dancer', @profile.display_name
    assert_equal 'beginner', @profile.experience_level
  end

  test 'rejects missing fields underage dancers and unsafe photo references' do
    @profile.age = 17
    @profile.primary_photo_url = 'javascript:alert(1)'
    @profile.dance_styles = []
    @profile.availability = ' '
    assert_not @profile.valid?
    %i[age primary_photo_url dance_styles availability].each { |field| assert @profile.errors[field].any? }
  end

  test 'database enforces one profile per user' do
    @profile.save!
    duplicate = @profile.dup
    assert_not duplicate.valid?
    assert_raises(ActiveRecord::RecordNotUnique) do
      Profile.transaction(requires_new: true) { duplicate.save!(validate: false) }
    end
  end
end
