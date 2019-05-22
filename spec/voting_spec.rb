# frozen_string_literal: true

require 'rails_helper'

describe DiscourseVoting do

  let(:user0) { Fabricate(:user) }
  let(:user1) { Fabricate(:user) }
  let(:user2) { Fabricate(:user) }
  let(:user3) { Fabricate(:user) }

  let(:category1) { Fabricate(:category) }
  let(:category2) { Fabricate(:category) }

  let(:topic0) { Fabricate(:topic, category: category1) }
  let(:topic1) { Fabricate(:topic, category: category2) }

  before do
    SiteSetting.voting_enabled = true
    SiteSetting.voting_allow_down_vote = false
    SiteSetting.voting_show_who_voted = true
  end

  it "doesn't allow users to vote more than they are allowed" do
    SiteSetting.voting_tl1_vote_limit = 1
    user0.update!(trust_level: 1)

    expect(user0.reached_voting_limit?).to eq(false)

    user0.custom_fields[DiscourseVoting::UP_VOTES] = [topic0.id.to_s]
    user0.save!

    expect(user0.reached_voting_limit?).to eq(true)
  end

  context "with two topics" do
    let(:users) { [user0, user1, user2, user3] }
    before do
      Fabricate(:post, topic: topic0, user: user0)
      Fabricate(:post, topic: topic0, user: user0)

      # +user0+ votes +topic0+, +user1+ votes +topic1+ and +user2+ votes both
      # topics.
      users[0].custom_fields[DiscourseVoting::UP_VOTES] = users[0].up_votes.dup.push(topic0.id.to_s)
      users[1].custom_fields[DiscourseVoting::UP_VOTES] = users[1].up_votes.dup.push(topic1.id.to_s)
      users[2].custom_fields[DiscourseVoting::UP_VOTES] = users[2].up_votes.dup.push(topic0.id.to_s)
      users[2].custom_fields[DiscourseVoting::UP_VOTES] = users[2].up_votes.dup.push(topic1.id.to_s)

      users.each { |u| u.save! }

      [topic0, topic1].each { |t| t.update_vote_count }
    end
    it 'moves votes when entire topic is merged' do
      topic0.move_posts(Discourse.system_user, topic0.posts.pluck(:id), destination_topic_id: topic1.id)

      users.each(&:reload)
      [topic0, topic1].each(&:reload)

      expect(users[0].up_votes).to eq([topic1.id])
      expect(users[1].up_votes).to eq([topic1.id])
      expect(users[2].up_votes).to eq([topic1.id])
      expect(users[3].up_votes).to eq([])

      expect(topic0.vote_count).to eq(0)
      expect(topic1.vote_count).to eq(3)
    end

    it 'does not move votes when a single post is moved' do
      topic0.move_posts(Discourse.system_user, topic0.posts[1, 2].map(&:id), destination_topic_id: topic1.id)

      users.each(&:reload)
      [topic0, topic1].each(&:reload)

      expect(users[0].up_votes).to eq([topic0.id])
      expect(users[1].up_votes).to eq([topic1.id])
      expect(users[2].up_votes).to eq([topic0.id, topic1.id])
      expect(users[3].up_votes).to eq([])

      expect(topic0.vote_count).to eq(2)
      expect(topic1.vote_count).to eq(2)
    end
  end

  context "when a user has an empty string as the votes custom field" do
    before do
      user0.custom_fields[DiscourseVoting::UP_VOTES] = ""
      user0.custom_fields[DiscourseVoting::UP_VOTES_ARCHIVE] = ""
      user0.save
      user0.reload
    end

    it "returns a vote count of zero" do
      expect(user0.vote_count).to eq (0)
      expect(user0.up_votes_archive).to eq ([])
    end
  end

  context "when topic status is changed" do
    it "enqueues a job for releasing/reclaiming votes" do
      DiscourseEvent.on(:topic_status_updated) do |topic|
        expect(topic).to be_instance_of(Topic)
      end

      topic1.update_status('closed', true, Discourse.system_user)
      expect(Jobs::VoteRelease.jobs.first["args"].first["topic_id"]).to eq(topic1.id)

      topic1.update_status('closed', false, Discourse.system_user)
      expect(Jobs::VoteReclaim.jobs.first["args"].first["topic_id"]).to eq(topic1.id)
    end
  end

  context "when a topic is moved to a category" do
    let(:admin) { Fabricate(:admin) }
    let(:post0) { Fabricate(:post, topic: topic0, post_number: 1) }
    let(:post1) { Fabricate(:post, topic: topic1, post_number: 1) }

    before do
      category1.custom_fields["enable_topic_voting"] = "true"
      category1.save!
      Category.reset_voting_cache
    end

    it "enqueus a job to reclaim votes if voting is enabled for the new category" do
      user = post1.user
      user.custom_fields[DiscourseVoting::UP_VOTES_ARCHIVE] = [post1.topic_id, 456456]
      user.save!

      PostRevisor.new(post1).revise!(admin, category_id: category1.id)
      expect(Jobs::VoteReclaim.jobs.first["args"].first["topic_id"]).to eq(post1.reload.topic_id)

      Jobs::VoteReclaim.new.execute(topic_id: post1.topic_id)
      user.reload

      expect(user.up_votes).to eq([post1.topic_id])
      expect(user.up_votes_archive).to eq([456456])
    end

    it "enqueus a job to release votes if voting is disabled for the new category" do
      user = post0.user
      user.custom_fields[DiscourseVoting::UP_VOTES] = [post0.topic_id, 456456]
      user.save!

      PostRevisor.new(post0).revise!(admin, category_id: category2.id)
      expect(Jobs::VoteRelease.jobs.first["args"].first["topic_id"]).to eq(post0.reload.topic_id)

      Jobs::VoteRelease.new.execute(topic_id: post0.topic_id)
      user.reload

      expect(user.up_votes_archive).to eq([post0.topic_id])
      expect(user.up_votes).to eq([456456])
    end

    it "doesn't enqueue a job if the topic has no votes" do
      PostRevisor.new(post0).revise!(admin, category_id: category2.id)
      expect(Jobs::VoteRelease.jobs.size).to eq(0)

      PostRevisor.new(post1).revise!(admin, category_id: category1.id)
      expect(Jobs::VoteReclaim.jobs.size).to eq(0)
    end
  end

  context "when down-voting is allowed" do
    before(:all) do
      SiteSetting.voting_allow_down_vote = true
    end

    it "counting votes correctly" do
      user0.custom_fields[DiscourseVoting::DOWN_VOTES] = [topic0.id, topic1.id]
      user1.custom_fields[DiscourseVoting::UP_VOTES] = [topic1.id]
      user0.save!
      user1.save!

      [topic0, topic1].each { |t| t.update_vote_count }

      expect(topic0.vote_count).to eq(-1)
      expect(topic1.vote_count).to eq(0)
    end
  end
end
