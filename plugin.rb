# name: post-approval-finish
# version: 0.0.2
# authors: boyned/Kampfkarren, buildthomas

# enabled_site_setting :post_approval_finish_enabled

after_initialize do
  module ::PostApprovalFinish
    class Engine < ::Rails::Engine
      engine_name "post_approval_finish"
      isolate_namespace PostApprovalFinish
    end
  end

  class PostApprovalFinish::PostApprovalFinishController < ::ApplicationController
    def action
      raise Discourse::InvalidAccess unless GroupUser.where(group_id: Group.find_by(name: SiteSetting.post_approval_finish_group).id)
        .where(user_id: current_user.id)
        .exists?

      # Validate post approval PM
      pm_topic = Topic.find_by(id: params[:pm_topic_id], archetype: Archetype.private_message)
      raise Discourse::InvalidParameters.new(:pm_topic_id) unless pm_topic

      # TODO: need to validate that current_user can access this PM

      # Validate whether badge should be awarded
      award_badge = params[:award_badge] || false
      raise Discourse::InvalidParameters.new(:title) unless ([true, false].include?(award_badge))

      if (params[:target_category_id] != nil)

        # Validate target category for new topic
        target_category = Category.find_by(id: params[:target_category_id])
        raise Discourse::InvalidParameters.new(:target_category_id) unless target_category

        # TODO: need to validate that current_user can post in this category

        # Validate title for the new topic
        title = params[:title]
        raise Discourse::InvalidParameters.new(:title) unless (title.instance_of?(String) &&
          title.length >= SiteSetting.min_topic_title_length && title.length <= SiteSetting.max_topic_title_length)

        # Validate tags for the new topic
        tags = params[:tags] == nil ? [] : params[:tags]
        raise Discourse::InvalidParameters.new(:tags) unless (tags.kind_of?(Array) &&
          tags.select{|s| !s.instance_of?(String) || s.length == 0}.length > 0) # All strings, non-empty

        # Create the new topic in the target category
        post = PostCreator.create(
          pm_topic.user,
          category: target_category.id,
          title: title,
          raw: pm_topic.posts.first.raw,
          user: pm_topic.user,
          tags: tags,
          custom_fields: {
            post_approval_finished: true # Make sure it triggers notifications
          }
          skip_validations: true, # They've already gone through the validations to make the topic first
        )

        # Complete the request
        finalize(current_user, pm_topic, post, should_award_badge)

      elsif (params[:target_topic_id] != nil)

        # Validate target existing topic for new reply
        target_topic = Topic.find_by(id: params[:target_topic_id], Archetype.default)
        raise Discourse::InvalidParameters.new(:target_topic_id) unless target_topic

        # TODO: need to validate that current_user can reply to this topic

        # Create the new reply on the target topic
        post = PostCreator.create(
          pm_topic.user,
          topic_id: pm_topic.id,
          raw: pm_topic.posts.first.raw,
          user: pm_topic.user,
          custom_fields: {
            post_approval_finished: true # Make sure it triggers notifications
          }
          skip_validations: true, # They've already gone through the validations to make the reply first
        )

        # Complete the request
        finalize(current_user, pm_topic, post, should_award_badge)

      else
        raise Discourse::InvalidParameters.new() # Can't do both a new topic / a reply at once
      end

      # No error encountered
      render json: success_json
    end

    # Archiving a private message
    def archive_message(topic)
      group_id = nil

      group_ids = current_user.groups.pluck(:id)
      if group_ids.present?
        allowed_groups = topic.allowed_groups
          .where('topic_allowed_groups.group_id IN (?)', group_ids).pluck(:id)
        allowed_groups.each do |id|
          GroupArchivedMessage.archive!(id, topic)
          group_id = id
        end
      end

      if topic.allowed_users.include?(current_user)
        UserArchivedMessage.archive!(current_user.id, topic)
      end
    end

    # Awarding the post approval badge for a post
    def award_badge(post)
      return unless SiteSetting.post_approval_finish_badge > 0 # not enabled
      return unless badge = Badge.find_by(id: SiteSetting.post_approval_finish_badge, enabled: true) # no badge found

      # TODO award badge here

    end

    # Whether post could have been posted without post approval
    def could_post_on_own(post)

      # TODO
      
      return false
    end

    # Getting the body for the final reply to the private message
    def make_body(post, should_award_badge)

      # Different entry text depending on whether it was a new topic / a reply
      is_topic = post.is_first_post?
      body = (is_topic ? SiteSetting.post_approval_finish_text_topic : SiteSetting.post_approval_finish_text_reply)

      # Attach a note if the user achieved a badge through this post approval request
      if should_award_badge
        body += "\n\n" + SiteSetting.post_approval_finish_text_badge
      end

      # Attach a note if the user could have posted without post approval
      if could_post_on_own(post)
        body += "\n\n" + (is_topic ? SiteSetting.post_approval_finish_text_topic_footer : SiteSetting.post_approval_finish_text_reply_footer)
      end

    end

    # Collection of actions to perform upon finalizing post approval
    def finalize(current_user, pm_topic, post, should_award_badge)

      # Award badge if applicable
      award_badge(post) if should_award_badge

      # Format body depending on input post
      body = make_body(post, should_award_badge)
        .gsub("%USER%", pm_topic.user.username)
        .gsub("%POST%", post.url)
      body = body.gsub("%CATEGORY%", post.category.name) if post.category

      # Send confirmation on private message
      reply = PostCreator.create(
        current_user,
        topic_id: pm_topic.id,
        raw: body,
        skip_validations: true,
      )

      # Mark confirmation as solution of private message
      DiscourseSolved.accept_answer!(reply, current_user)

      # Archive the private message
      archive_message(pm_topic)

      pm_topic.reload
      pm_topic.save

    end
  end

  PostApprovalFinish::Engine.routes.draw do
    post "/post-approval-finish" => "post_approval_finish#action"
  end

  Discourse::Application.routes.append do
    mount ::PostApprovalFinish::Engine, at: "/"
  end
end
