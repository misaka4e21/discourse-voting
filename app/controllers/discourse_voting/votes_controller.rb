# frozen_string_literal: true

module DiscourseVoting
  class VotesController < ::ApplicationController
    before_action :ensure_logged_in

    def who
      params.require(:topic_id)
      topic = Topic.find(params[:topic_id].to_i)
      guardian.ensure_can_see!(topic)

      render json: MultiJson.dump(who_voted(topic))
    end

    def up_vote
      topic_id = params["topic_id"].to_i
      topic = Topic.find_by(id: topic_id)

      raise Discourse::InvalidAccess if !topic.can_vote? || topic.user_up_voted(current_user)
      guardian.ensure_can_see!(topic)

      voted = false

      unless current_user.reached_voting_limit?
        current_user.custom_fields[DiscourseVoting::DOWN_VOTES] = current_user.down_votes.dup - [topic_id]
        current_user.custom_fields[DiscourseVoting::UP_VOTES] = current_user.up_votes.dup.push(topic_id).uniq
        current_user.save!

        topic.update_vote_count
        voted = true
      end

      obj = {
        can_vote: !current_user.reached_voting_limit?,
        vote_limit: current_user.vote_limit,
        vote_count: topic.custom_fields[DiscourseVoting::VOTE_COUNT].to_i,
        who_voted: who_voted(topic),
        alert: current_user.alert_low_votes?,
        votes_left: [(current_user.vote_limit - current_user.vote_count), 0].max
      }

      render json: obj, status: voted ? 200 : 403
    end

    def unvote
      topic_id = params["topic_id"].to_i
      topic = Topic.find_by(id: topic_id)

      guardian.ensure_can_see!(topic)

      current_user.custom_fields[DiscourseVoting::UP_VOTES] = current_user.up_votes.dup - [topic_id]
      current_user.custom_fields[DiscourseVoting::DOWN_VOTES] = current_user.down_votes.dup - [topic_id]
      current_user.save!

      topic.update_vote_count

      obj = {
        can_vote: !current_user.reached_voting_limit?,
        vote_limit: current_user.vote_limit,
        vote_count: topic.custom_fields[DiscourseVoting::VOTE_COUNT].to_i,
        who_voted: who_voted(topic),
        votes_left: [(current_user.vote_limit - current_user.vote_count), 0].max
      }

      render json: obj
    end

    def down_vote
      topic_id = params["topic_id"].to_i
      topic = Topic.find_by(id: topic_id)

      raise Discourse::InvalidAccess if !topic.can_down_vote? || topic.user_down_voted(current_user)
      guardian.ensure_can_see!(topic)

      voted = false

      unless current_user.reached_voting_limit?
        current_user.custom_fields[DiscourseVoting::UP_VOTES] = current_user.up_votes.dup - [topic_id]
        current_user.custom_fields[DiscourseVoting::DOWN_VOTES] = current_user.down_votes.dup.push(topic_id).uniq
        current_user.save!

        topic.update_vote_count
        voted = true
      end

      obj = {
        can_vote: !current_user.reached_voting_limit?,
        vote_limit: current_user.vote_limit,
        vote_count: topic.custom_fields[DiscourseVoting::VOTE_COUNT].to_i,
        who_voted: who_voted(topic),
        alert: current_user.alert_low_votes?,
        votes_left: [(current_user.vote_limit - current_user.vote_count), 0].max
      }

      render json: obj, status: voted ? 200 : 403
    end

    protected

    def who_voted(topic)
      return nil unless SiteSetting.voting_show_who_voted

      ActiveModel::ArraySerializer.new(topic.who_up_voted, scope: guardian, each_serializer: BasicUserSerializer)
    end

  end
end
