# frozen_string_literal: true

require 'rails_helper'

describe DiscourseVoting::VotesController do

  let(:user) { Fabricate(:user) }
  let(:category) { Fabricate(:category) }
  let(:topic) { Fabricate(:topic, category_id: category.id) }

  before do
    CategoryCustomField.create!(category_id: category.id, name: "enable_topic_voting", value: "true")
    Category.reset_voting_cache
    SiteSetting.voting_show_who_voted = true
    SiteSetting.voting_enabled = true
    SiteSetting.voting_allow_down_vote = false
    sign_in(user)
  end

  it "does not allow voting if voting is not enabled" do
    SiteSetting.voting_enabled = false
    post "/voting/up_vote.json", params: { topic_id: topic.id }
    expect(response.status).to eq(403)
  end

  it "can correctly show deal with voting workflow" do

    SiteSetting.public_send "voting_tl#{user.trust_level}_vote_limit=", 2

    post "/voting/up_vote.json", params: { topic_id: topic.id }
    expect(response.status).to eq(200)

    post "/voting/up_vote.json", params: { topic_id: topic.id }
    expect(response.status).to eq(403)
    expect(topic.reload.vote_count).to eq(1)
    expect(user.reload.vote_count).to eq(1)

    get "/voting/who.json", params: { topic_id: topic.id }
    expect(response.status).to eq(200)
    json = JSON.parse(response.body)
    expect(json.length).to eq(1)
    expect(json.first.keys.sort).to eq(["avatar_template", "id", "name", "username"])
    expect(json.first["id"]).to eq(user.id)

    post "/voting/unvote.json", params: { topic_id: topic.id }
    expect(response.status).to eq(200)

    expect(topic.reload.vote_count).to eq(0)
    expect(user.reload.vote_count).to eq(0)
  end

  context "when a user has tallyed votes with no topic id" do
    before do
      user.custom_fields[DiscourseVoting::UP_VOTES] = [nil, nil, nil]
      user.save
    end

    it "removes extra votes" do
      post "/voting/up_vote.json", params: { topic_id: topic.id }
      expect(response.status).to eq(200)
      expect(user.reload.vote_count).to eq (1)
    end
  end

  context "down votes" do
    before do
      SiteSetting.voting_allow_down_vote = true
    end

    it "does not allow down voting if it is not enabled" do
      SiteSetting.voting_allow_down_vote = false
      post "/voting/down_vote.json", params: { topic_id: topic.id }
      expect(response.status).to eq(403)
    end

    it "can correctly show deal with down voting workflow" do

      SiteSetting.public_send "voting_tl#{user.trust_level}_vote_limit=", 2

      post "/voting/down_vote.json", params: { topic_id: topic.id }
      expect(response.status).to eq(200)

      post "/voting/down_vote.json", params: { topic_id: topic.id }
      expect(response.status).to eq(403)
      expect(topic.reload.vote_count).to eq(-1)
      expect(user.reload.vote_count).to eq(1)

      # Don't show down-voters
      get "/voting/who.json", params: { topic_id: topic.id }
      expect(response.status).to eq(200)
      json = JSON.parse(response.body)
      expect(json.length).to eq(0)

      post "/voting/unvote.json", params: { topic_id: topic.id }
      expect(response.status).to eq(200)

      expect(topic.reload.vote_count).to eq(0)
      expect(user.reload.vote_count).to eq(0)
    end
  end
end
