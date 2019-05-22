# frozen_string_literal: true

# name: discourse-voting
# about: Adds the ability to vote on features in a specified category.
# version: 0.4
# author: Joe Buhlig joebuhlig.com, Sam Saffron
# url: https://github.com/discourse/discourse-voting

register_asset "stylesheets/common/feature-voting.scss"
register_asset "stylesheets/desktop/feature-voting.scss", :desktop
register_asset "stylesheets/mobile/feature-voting.scss", :mobile

enabled_site_setting :voting_enabled

Discourse.top_menu_items.push(:votes)
Discourse.anonymous_top_menu_items.push(:votes)
Discourse.filters.push(:votes)
Discourse.anonymous_filters.push(:votes)

after_initialize do
  module ::DiscourseVoting
    UP_VOTES = "votes".freeze
    UP_VOTES_ARCHIVE = "votes_archive".freeze
    VOTE_COUNT = "vote_count".freeze
    DOWN_VOTES = "down_votes".freeze
    DOWN_VOTES_ARCHIVE = "votes_archive".freeze

    class Engine < ::Rails::Engine
      isolate_namespace DiscourseVoting
    end
  end

  User.register_custom_field_type(::DiscourseVoting::UP_VOTES, [:integer])
  User.register_custom_field_type(::DiscourseVoting::UP_VOTES_ARCHIVE, [:integer])
  User.register_custom_field_type(::DiscourseVoting::DOWN_VOTES, [:integer])
  User.register_custom_field_type(::DiscourseVoting::DOWN_VOTES_ARCHIVE, [:integer])
  Topic.register_custom_field_type(::DiscourseVoting::VOTE_COUNT, :integer)

  load File.expand_path('../app/jobs/onceoff/voting_ensure_consistency.rb', __FILE__)

  require_dependency 'basic_category_serializer'
  class ::BasicCategorySerializer
    attributes :can_vote

    def include_can_vote?
      Category.can_vote?(object.id)
    end

    def can_vote
      true
    end

  end

  require_dependency 'post_serializer'
  class ::PostSerializer
    attributes :can_vote

    def include_can_vote?
      object.post_number == 1 && object.topic && object.topic.can_vote?
    end

    def can_vote
      true
    end
  end

  require_dependency 'topic_view_serializer'
  class ::TopicViewSerializer
    attributes :can_vote, :vote_count, :user_voted

    def can_vote
      object.topic.can_vote?
    end

    def vote_count
      object.topic.vote_count
    end

    def user_voted
      user_up_voted || user_down_voted
    end

    def user_up_voted
      if scope.user
        object.topic.user_up_voted(scope.user)
      else
        false
      end
    end

    def user_down_voted
      if scope.user
        object.topic.user_down_voted(scope.user)
      else
        false
      end
    end
  end

  add_to_serializer(:topic_list_item, :vote_count) { object.vote_count }
  add_to_serializer(:topic_list_item, :can_vote) { object.can_vote? }
  add_to_serializer(:topic_list_item, :user_voted) {
    object.user_voted(scope.user) if scope.user
  }
  add_to_serializer(:topic_list_item, :user_up_voted) {
    object.user_up_voted(scope.user) if scope.user
  }
  add_to_serializer(:topic_list_item, :user_down_voted) {
    object.user_down_voted(scope.user) if scope.user
  }

  class ::Category
    def self.reset_voting_cache
      @allowed_voting_cache["allowed"] =
        begin
          Set.new(
            CategoryCustomField
            .where(name: "enable_topic_voting", value: "true")
            .pluck(:category_id)
          )
        end
    end

    @allowed_voting_cache = DistributedCache.new("allowed_voting")

    def self.can_vote?(category_id)
      return false unless SiteSetting.voting_enabled

      unless set = @allowed_voting_cache["allowed"]
        set = reset_voting_cache
      end
      set.include?(category_id)
    end

    after_save :reset_voting_cache

    protected
    def reset_voting_cache
      ::Category.reset_voting_cache
    end
  end

  require_dependency 'user'
  class ::User
    def vote_count
      up_votes.length + down_votes.length
    end

    def alert_low_votes?
      (vote_limit - vote_count) <= SiteSetting.voting_alert_votes_left
    end

    def up_votes
      up_votes = self.custom_fields[DiscourseVoting::UP_VOTES] || []
      # "" can be in there sometimes, it gets turned into a 0
      up_votes = up_votes.reject { |v| v == 0 }.uniq
      up_votes
    end

    def up_votes_archive
      archived_up_votes = self.custom_fields[DiscourseVoting::UP_VOTES_ARCHIVE] || []
      archived_up_votes = archived_up_votes.reject { |v| v == 0 }.uniq
      archived_up_votes
    end

    def down_votes
      down_votes = self.custom_fields[DiscourseVoting::DOWN_VOTES] || []
      # "" can be in there sometimes, it gets turned into a 0
      down_votes = down_votes.reject { |v| v == 0 }.uniq
      down_votes
    end

    def down_votes_archive
      down_votes_archive = self.custom_fields[DiscourseVoting::DOWN_VOTES_ARCHIVE] || []
      down_votes_archive = down_votes_archive.reject { |v| v == 0 }.uniq
      down_votes_archive
    end

    def reached_voting_limit?
      vote_count >= vote_limit
    end

    def vote_limit
      SiteSetting.public_send("voting_tl#{self.trust_level}_vote_limit")
    end

  end

  require_dependency 'current_user_serializer'
  class ::CurrentUserSerializer
    attributes :votes_exceeded,  :vote_count

    def votes_exceeded
      object.reached_voting_limit?
    end

    def vote_count
      object.vote_count
    end

  end

  require_dependency 'topic'
  class ::Topic

    def can_vote?
      SiteSetting.voting_enabled && Category.can_vote?(category_id) && category.topic_id != id
    end

    def can_down_vote?
      SiteSetting.voting_enabled && SiteSetting.voting_allow_down_vote && Category.can_vote?(category_id) && category.topic_id != id
    end

    def vote_count
      if count = self.custom_fields[DiscourseVoting::VOTE_COUNT]
        # we may have a weird array here, don't explode
        # need to fix core to enforce types on fields
        count.try(:to_i) || 0
      else
        0 if self.can_vote?
      end
    end

    def user_voted(user)
      user_up_voted(user) || user_down_voted(user)
    end

    def user_up_voted(user)
      if user && user.custom_fields[DiscourseVoting::UP_VOTES]
        user.custom_fields[DiscourseVoting::UP_VOTES].include? self.id
      else
        false
      end
    end

    def user_down_voted(user)
      if user && user.custom_fields[DiscourseVoting::DOWN_VOTES]
        user.custom_fields[DiscourseVoting::DOWN_VOTES].include? self.id
      else
        false
      end
    end

    def update_vote_count
      up_count =
        UserCustomField.where("value = :value AND name IN (:keys)",
          value: id.to_s, keys: [DiscourseVoting::UP_VOTES, DiscourseVoting::UP_VOTES_ARCHIVE]).count
      down_count =
          UserCustomField.where("value = :value AND name IN (:keys)",
            value: id.to_s, keys: [DiscourseVoting::DOWN_VOTES, DiscourseVoting::DOWN_VOTES_ARCHIVE]).count

      custom_fields[DiscourseVoting::VOTE_COUNT] = up_count - down_count
      save_custom_fields
    end

    def who_voted
      who_up_voted
    end

    def who_up_voted
      # Return who_voted even if SiteSetting.voting_show_who_voted is disabled.
      # it will be check in the controller.
      User.where("id in (
        SELECT user_id FROM user_custom_fields WHERE name IN (:keys) AND value = :value
      )", value: id.to_s, keys: [DiscourseVoting::UP_VOTES, DiscourseVoting::UP_VOTES_ARCHIVE])
    end
    def who_down_voted
      User.where("id in (
        SELECT user_id FROM user_custom_fields WHERE name IN (:keys) AND value = :value
      )", value: id.to_s, keys: [DiscourseVoting::DOWN_VOTES, DiscourseVoting::DOWN_VOTES_ARCHIVE])
    end

  end

  require_dependency 'list_controller'
  class ::ListController
    def voted_by
      unless SiteSetting.voting_show_votes_on_profile
        render nothing: true, status: 404
      end
      list_opts = build_topic_list_options
      target_user = fetch_user_from_params(include_inactive: current_user.try(:staff?))
      list = generate_list_for("voted_by", target_user, list_opts)
      list.more_topics_url = url_for(construct_url_with(:next, list_opts))
      list.prev_topics_url = url_for(construct_url_with(:prev, list_opts))
      respond_with_list(list)
    end
  end

  require_dependency 'topic_query'
  class ::TopicQuery
    SORTABLE_MAPPING["votes"] = "custom_fields.#{::DiscourseVoting::VOTE_COUNT}"

    def list_voted_by(user)
      create_list(:user_topics) do |topics|
        topics.where(id: user.custom_fields[DiscourseVoting::UP_VOTES])
      end
    end

    def list_votes
      create_list(:votes, unordered: true) do |topics|
        topics.joins("left join topic_custom_fields tfv ON tfv.topic_id = topics.id AND tfv.name = '#{DiscourseVoting::VOTE_COUNT}'")
          .order("coalesce(tfv.value,'0')::integer desc, topics.bumped_at desc")
      end
    end
  end

  require_dependency "jobs/base"
  module ::Jobs

    class VoteRelease < Jobs::Base
      def execute(args)
        if topic = Topic.find_by(id: args[:topic_id])
          UserCustomField.where(name: DiscourseVoting::UP_VOTES, value: args[:topic_id]).find_each do |user_field|
            user = User.find(user_field.user_id)
            user.custom_fields[DiscourseVoting::UP_VOTES] = user.up_votes.dup - [args[:topic_id]]
            user.custom_fields[DiscourseVoting::UP_VOTES_ARCHIVE] = user.up_votes_archive.dup.push(args[:topic_id]).uniq
            user.save!
          end
          UserCustomField.where(name: DiscourseVoting::DOWN_VOTES, value: args[:topic_id]).find_each do |user_field|
            user = User.find(user_field.user_id)
            user.custom_fields[DiscourseVoting::DOWN_VOTES] = user.down_votes.dup - [args[:topic_id]]
            user.custom_fields[DiscourseVoting::DOWN_VOTES_ARCHIVE] = user.down_votes_archive.dup.push(args[:topic_id]).uniq
            user.save!
          end
          topic.update_vote_count
        end
      end
    end

    class VoteReclaim < Jobs::Base
      def execute(args)
        if topic = Topic.find_by(id: args[:topic_id])
          UserCustomField.where(name: DiscourseVoting::UP_VOTES_ARCHIVE, value: topic.id).find_each do |user_field|
            user = User.find(user_field.user_id)
            user.custom_fields[DiscourseVoting::UP_VOTES] = user.up_votes.dup.push(topic.id).uniq
            user.custom_fields[DiscourseVoting::UP_VOTES_ARCHIVE] = user.up_votes_archive.dup - [topic.id]
            user.save!
          end

          UserCustomField.where(name: DiscourseVoting::DOWN_VOTES_ARCHIVE, value: topic.id).find_each do |user_field|
            user = User.find(user_field.user_id)
            user.custom_fields[DiscourseVoting::DOWN_VOTES] = user.up_votes.dup.push(topic.id).uniq
            user.custom_fields[DiscourseVoting::DOWN_VOTES_ARCHIVE] = user.up_votes_archive.dup - [topic.id]
            user.save!
          end
          topic.update_vote_count
        end
      end
    end

  end

  DiscourseEvent.on(:topic_status_updated) do |topic, status, enabled|
    if (status == 'closed' || status == 'autoclosed' || status == 'archived') && enabled == true
      Jobs.enqueue(:vote_release, topic_id: topic.id)
    end

    if (status == 'closed' || status == 'autoclosed' || status == 'archived') && enabled == false
      Jobs.enqueue(:vote_reclaim, topic_id: topic.id)
    end
  end

  DiscourseEvent.on(:post_edited) do |post, topic_changed|
    if topic_changed &&
        SiteSetting.voting_enabled &&
        UserCustomField.where(
          "value = :value AND name in (:keys)",
          value: post.topic_id.to_s,
          keys: [DiscourseVoting::UP_VOTES, DiscourseVoting::UP_VOTES_ARCHIVE, DiscourseVoting::DOWN_VOTES, DiscourseVoting::DOWN_VOTES_ARCHIVE]
        ).exists?
      new_category_id = post.reload.topic.category_id
      if Category.can_vote?(new_category_id)
        Jobs.enqueue(:vote_reclaim, topic_id: post.topic_id)
      else
        Jobs.enqueue(:vote_release, topic_id: post.topic_id)
      end
    end
  end

  DiscourseEvent.on(:topic_merged) do |orig, dest|
    if orig.who_voted.present? && orig.closed
      orig.who_voted.each do |user|

        if user.up_votes.include?(dest.id)
          # User has voted for both +orig+ and +dest+.
          # Remove vote for topic +orig+.
          user.custom_fields[DiscourseVoting::UP_VOTES] = user.up_votes.dup - [orig.id]
        else
          # Change the vote for +orig+ in a vote for +dest+.
          user.custom_fields[DiscourseVoting::UP_VOTES] = user.up_votes.map { |vote| vote == orig.id ? dest.id : vote }
        end

        user.save!
      end
    end

    if orig.who_down_voted.present? && orig.closed
      orig.who_down_voted.each do |user|

        if user.down_votes.include?(dest.id)
          # User has voted for both +orig+ and +dest+.
          # Remove vote for topic +orig+.
          user.custom_fields[DiscourseVoting::DOWN_VOTES] = user.down_votes.dup - [orig.id]
        else
          # Change the vote for +orig+ in a vote for +dest+.
          user.custom_fields[DiscourseVoting::DOWN_VOTES] = user.down_votes.map { |vote| vote == orig.id ? dest.id : vote }
        end

        user.save!
      end
    end

    orig.update_vote_count
    dest.update_vote_count
  end

  require File.expand_path(File.dirname(__FILE__) + '/app/controllers/discourse_voting/votes_controller')

  DiscourseVoting::Engine.routes.draw do
    post 'up_vote' => 'votes#up_vote'
    post 'unvote' => 'votes#unvote'
    post 'down_vote' => 'votes#down_vote'
    get 'who' => 'votes#who'
  end

  Discourse::Application.routes.append do
    mount ::DiscourseVoting::Engine, at: "/voting"
    # USERNAME_ROUTE_FORMAT is deprecated but we may need to support it for older installs
    username_route_format = defined?(RouteFormat) ? RouteFormat.username : USERNAME_ROUTE_FORMAT
    get "topics/voted-by/:username" => "list#voted_by", as: "voted_by", constraints: { username: username_route_format }
  end

  TopicList.preloaded_custom_fields << DiscourseVoting::VOTE_COUNT if TopicList.respond_to? :preloaded_custom_fields
end
