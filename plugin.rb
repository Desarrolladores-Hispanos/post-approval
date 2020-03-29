# name: post-approval
# version: 0.4.0
# authors: buildthomas, boyned/Kampfkarren

enabled_site_setting :post_approval_enabled

register_asset "stylesheets/common/base/post-approval-modal.scss"
register_asset "stylesheets/desktop/post-approval-modal.scss", :desktop

after_initialize do

  # Extend categories with extra properties

  require_dependency "category"

  Site.preloaded_category_custom_fields << "pa_redirect_topic_enabled"
  Site.preloaded_category_custom_fields << "pa_redirect_topic_message"
  Site.preloaded_category_custom_fields << "pa_redirect_reply_enabled"
  Site.preloaded_category_custom_fields << "pa_redirect_reply_message"

  register_category_custom_field_type("pa_redirect_topic_enabled", :boolean)
  register_category_custom_field_type("pa_redirect_topic_message", :text)
  register_category_custom_field_type("pa_redirect_reply_enabled", :boolean)
  register_category_custom_field_type("pa_redirect_reply_message", :text)

  class ::Category
    def pa_redirect_topic_enabled
      self.custom_fields["pa_redirect_topic_enabled"]
    end

    def pa_redirect_topic_message
      self.custom_fields["pa_redirect_topic_message"]
    end
    
    def pa_redirect_reply_enabled
      self.custom_fields["pa_redirect_reply_enabled"]
    end

    def pa_redirect_reply_message
      self.custom_fields["pa_redirect_reply_message"]
    end
  end

  add_to_serializer(:basic_category, :pa_redirect_topic_enabled) { object.pa_redirect_topic_enabled }
  add_to_serializer(:basic_category, :pa_redirect_topic_message) { object.pa_redirect_topic_message }
  add_to_serializer(:basic_category, :pa_redirect_reply_enabled) { object.pa_redirect_reply_enabled }
  add_to_serializer(:basic_category, :pa_redirect_reply_message) { object.pa_redirect_reply_message }

  add_to_serializer(:post, :pa_target_topic_id) { object.custom_fields["pa_target_topic_id"] }
  add_to_serializer(:post, :include_pa_target_topic_id?) { object.custom_fields["pa_target_topic_id"] != nil }

  # Prevent low TLs from editing topics into redirected categories

  module GuardianInterceptor
    def can_move_topic_to_category?(category)
      if SiteSetting.post_approval_enabled && SiteSetting.post_approval_redirect_enabled
        category = Category === category ? category : Category.find(category || SiteSetting.uncategorized_category_id)

        return false if (category.pa_redirect_topic_enabled && user.trust_level <= SiteSetting.post_approval_redirect_tl_max)
      end
      super(category)
    end
  end
  Guardian.send(:prepend, GuardianInterceptor)

  # Prevent first post notifications on topics that are about to be redirected

  module PostAlerterInterceptor
    def is_redirectable_topic(topic)
      category = topic.category
      return SiteSetting.post_approval_enabled &&
        SiteSetting.post_approval_redirect_enabled &&
        SiteSetting.post_approval_redirect_topic_group.present? &&
        !(topic.custom_fields["post_approval"]) && # suppress notifications unless post was already approved
        topic.user&.trust_level <= SiteSetting.post_approval_redirect_tl_max &&
        category && category.pa_redirect_topic_enabled
    end
    module_function :is_redirectable_topic

    def is_redirectable_reply(reply)
      category = Category.find_by(id: reply.topic.category_id)
      return SiteSetting.post_approval_enabled &&
        SiteSetting.post_approval_redirect_enabled &&
        SiteSetting.post_approval_redirect_reply_group.present? &&
        !(reply.custom_fields["post_approval"]) && # suppress notifications unless post was already approved
        reply.user&.trust_level <= SiteSetting.post_approval_redirect_tl_max &&
        reply.topic.user != reply.user &&
        category && category.pa_redirect_reply_enabled
    end
    module_function :is_redirectable_reply

    def after_save_post(post, new_record)
      # Do not pass to super if this is a post that is about to be redirected
      if post.is_first_post?
        return if PostAlerterInterceptor.is_redirectable_topic(post.topic)
      else
        return if PostAlerterInterceptor.is_redirectable_reply(post)
      end
      super(post, new_record)
    end
  end
  PostAlerter.send(:prepend, PostAlerterInterceptor)

  # Redirect topics on creation

  def redirect_topic(topic)
    # Find post approval team group
    group = Group.lookup_group(SiteSetting.post_approval_redirect_topic_group)

    # Turn it into a private message
    request_category = topic.category
    TopicConverter.new(topic, Discourse.system_user).convert_to_private_message

    # Turn first post into wiki and include category in title
    topic.first_post.revise(
      Discourse.system_user,
      title: (SiteSetting.post_approval_redirect_topic_prefix % [request_category.name]) + topic.title,
      wiki: true,
      bypass_rate_limiter: true,
      skip_validations: true
    )
    topic.first_post.reload
    
    topic.save
    topic.reload

    # Give system response to the message with details
    PostCreator.create(
      Discourse.system_user,
      raw: request_category.pa_redirect_topic_message,
      topic_id: topic.id,
      skip_validations: true
    )

    # Invite post approval
    TopicAllowedGroup.create!(topic_id: topic.id, group_id: group.id)

    # Send invite notification to post approval team members
    group.users.where(
      "group_users.notification_level in (:levels) AND user_id != :id",
      levels: [NotificationLevels.all[:watching], NotificationLevels.all[:watching_first_post]],
      id: topic.user.id
    ).find_each do |u|
      u.notifications.create!(
        notification_type: Notification.types[:invited_to_private_message],
        topic_id: topic.id,
        post_number: 1,
        data: {
          topic_title: topic.title,
          display_username: topic.user.username,
          group_id: group.id
        }.to_json
      )
    end
  end

  def redirect_reply(reply)
    # Find post approval team group
    group = Group.lookup_group(SiteSetting.post_approval_redirect_reply_group)

    target_topic = reply.topic
    request_category = target_topic.category

    # Respect message title bounds
    title = SiteSetting.post_approval_redirect_reply_prefix + target_topic.title
    if title.length > SiteSetting.max_topic_title_length
      title = title[0, SiteSetting.max_topic_title_length - 3] << "..."
    end

    # Make new post approval private message
    pm = PostCreator.create(
      reply.user,
      title: title,
      raw: reply.raw,
      archetype: Archetype.private_message,
      target_group_names: [group.name],
      wiki: true,
      custom_fields: {
        pa_target_topic_id: target_topic.id, # create a hidden link to the target topic
        pa_reply_to_post_id: reply.reply_to_post&.id
      },
      bypass_rate_limiter: true,
      skip_validations: true
    )

    # Delete the reply
    reply.revise(
      Discourse.system_user,
      raw: SiteSetting.post_approval_redirect_reply_notice.gsub("%URL%", pm.url) + "\n\n---\n\n" + reply.raw,
      skip_validations: true
    )
    PostDestroyer.new(Discourse.system_user, reply).destroy

    # Unbump from Latest
    target_topic.reset_bumped_at

    # Give system response to the message with details
    PostCreator.create(
      Discourse.system_user,
      raw: request_category.pa_redirect_reply_message.gsub("%TOPIC%", "[#{target_topic.title}](#{target_topic.url})"),
      topic_id: pm.topic.id,
      skip_validations: true
    )

    # Send invite notification to post approval team members
    group.users.where(
      "group_users.notification_level in (:levels) AND user_id != :id",
      levels: [NotificationLevels.all[:watching], NotificationLevels.all[:watching_first_post]],
      id: pm.user.id
    ).find_each do |u|
      u.notifications.create!(
        notification_type: Notification.types[:invited_to_private_message],
        topic_id: pm.topic.id,
        post_number: 1,
        data: {
          topic_title: pm.topic.title,
          display_username: pm.user.username,
          group_id: group.id
        }.to_json
      )
    end
  end

  DiscourseEvent.on(:post_created) do |post|
    if post.is_first_post?

      # Make sure new private messages to post approval group are turned into wikis
      if SiteSetting.post_approval_enabled &&
        post.topic.archetype == Archetype.private_message &&

        group_topic = Group.lookup_group(SiteSetting.post_approval_redirect_topic_group)
        group_reply = Group.lookup_group(SiteSetting.post_approval_redirect_reply_group)
        if (group_topic && post.topic.topic_allowed_groups.find_by(group_id: group_topic.id)) ||
           (group_reply && post.topic.topic_allowed_groups.find_by(group_id: group_reply.id))

          post.revise(
            Discourse.system_user,
            wiki: true,
            bypass_rate_limiter: true,
            skip_validations: true
          )
          
        end
      end

      # Only proceed if the topic needs to be redirected
      redirect_topic(post.topic) if PostAlerterInterceptor.is_redirectable_topic(post.topic)

    else

      # Only proceed if the reply needs to be redirected
      redirect_reply(post) if PostAlerterInterceptor.is_redirectable_reply(post)

    end
  end

  # Whenever post approval inbox is queried, order based on user settings
  module TopicQueryInterceptor
    def private_messages_for(user, type)
      return super(user, type) unless SiteSetting.post_approval_enabled && type == :group &&
        (@options[:group_name] == SiteSetting.post_approval_redirect_topic_group ||
          @options[:group_name] == SiteSetting.post_approval_redirect_reply_group) &&
        @user.custom_fields["pa_sort_inversed"]

      options = @options
      options.reverse_merge!(per_page: per_page_setting)

      result = Topic.includes(:tags)
      result = result.includes(:allowed_users)
      result = result.where("
        topics.id IN (
          SELECT topic_id FROM topic_allowed_groups
          WHERE (
            group_id IN (
              SELECT group_id
              FROM group_users
              WHERE user_id = #{user.id.to_i}
              OR #{user.staff?}
            )
          )
          AND group_id IN (SELECT id FROM groups WHERE name ilike ?)
        )",
        @options[:group_name]
      )

      result = result.joins("LEFT OUTER JOIN topic_users AS tu ON (topics.id = tu.topic_id AND tu.user_id = #{user.id.to_i})")
        .order("topics.bumped_at ASC") # This is the only change (DESC --> ASC)
        .private_messages

      result = result.limit(options[:per_page]) unless options[:limit] == false
      result = result.visible if options[:visible] || @user.nil? || @user.regular?

      if options[:page]
        offset = options[:page].to_i * options[:per_page]
        result = result.offset(offset) if offset > 0
      end

      result
    end
  end
  TopicQuery.send(:prepend, TopicQueryInterceptor)

  # Whenever post approval group is invited to a private message, turn it into a wiki
  module TopicInterceptor
    def invite_group(user, group)
      if SiteSetting.post_approval_enabled &&
        (group.name == SiteSetting.post_approval_redirect_topic_group ||
          group.name == SiteSetting.post_approval_redirect_reply_group)
      
        first_post.revise(
          Discourse.system_user,
          wiki: true,
          bypass_rate_limiter: true,
          skip_validations: true
        )
      end

      super(user, group)
    end
  end
  Topic.send(:prepend, TopicInterceptor)

  # Post approval completion endpoint

  module ::PostApproval
    class Engine < ::Rails::Engine
      engine_name "post_approval"
      isolate_namespace PostApproval
    end
  end

  class PostApproval::PostApprovalController < ::ApplicationController
    def to_bool(value)
      return true   if value == true   || value =~ (/(true|t|yes|y|1)$/i)
      return false  if value == false  || value.blank? || value =~ (/(false|f|no|n|0)$/i)

      return nil # invalid
    end

    def action
      raise Discourse::NotFound.new unless SiteSetting.post_approval_enabled &&
        SiteSetting.post_approval_button_enabled
      
      raise Discourse::InvalidAccess.new unless Group.find_by(name: SiteSetting.post_approval_button_group).users.include?(current_user)

      # Validate post approval PM
      pm_topic = Topic.find_by(id: params[:pm_topic_id], archetype: Archetype.private_message)
      raise Discourse::InvalidParameters.new(:pm_topic_id) unless (pm_topic && Guardian.new(current_user).can_see_topic?(pm_topic))

      # Validate whether badge should be awarded
      award_badge = to_bool(params[:award_badge])
      raise Discourse::InvalidParameters.new(:award_badge) if (award_badge == nil)

      could_post_on_own = (pm_topic.user.trust_level > SiteSetting.post_approval_redirect_tl_max)

      post = nil # will contain the approved post
      target_category = nil

      if (!params[:target_category_id].blank?)

        # Validate target category for new topic
        target_category = Category.find_by(id: params[:target_category_id])
        raise Discourse::InvalidParameters.new(:target_category_id) unless (target_category && Guardian.new(current_user).can_move_topic_to_category?(target_category))

        # Validate title for the new topic
        title = params[:title]
        raise Discourse::InvalidParameters.new(:title) unless (title.instance_of?(String) &&
          title.length >= SiteSetting.min_topic_title_length && title.length <= SiteSetting.max_topic_title_length)

        # Validate tags for the new topic
        tags = params[:tags]
        if tags.blank?
          tags = []
        end
        raise Discourse::InvalidParameters.new(:tags) unless (tags.kind_of?(Array) &&
          tags.select{|s| !s.instance_of?(String) || s.length == 0}.length == 0) # All strings, non-empty

        if Guardian.new(pm_topic.user).can_move_topic_to_category?(target_category)
          could_post_on_own = true
        end

        # Create the new topic in the target category
        post = PostCreator.create(
          pm_topic.user,
          category: target_category.id,
          title: title,
          raw: pm_topic.posts.first.raw,
          user: pm_topic.user,
          tags: tags,
          custom_fields: {
            post_approval: true # marker to let ourselves know not to suppress notifications
          },
          skip_validations: true, # They've already gone through the validations to make the topic first
          skip_guardian: true,
        )

      elsif (!params[:target_topic_id].blank?)

        # Validate target existing topic for new reply
        target_topic = Topic.find_by(id: params[:target_topic_id], archetype: Archetype.default)
        raise Discourse::InvalidParameters.new(:target_topic_id) unless (target_topic && Guardian.new(current_user).can_create_post_on_topic?(target_topic))

        target_category = Category.find_by(id: target_topic.category_id)

        could_post_on_own = Guardian.new(pm_topic.user).can_create_post_on_topic?(target_topic) &&
          !(target_category && target_category.pa_redirect_reply_enabled)

        # Find post number of the post the user was originally replying to
        reply_to_post_number = nil
        if pm_topic.custom_fields["pa_reply_to_post_id"] && target_topic.id == pm_topic.custom_fields["pa_target_topic_id"].to_i
          reply_to_post_number = Post.with_deleted.find_by(id: pm_topic.custom_fields["pa_reply_to_post_id"])&.post_number
        end

        # Create the new reply on the target topic
        post = PostCreator.create(
          pm_topic.user,
          topic_id: target_topic.id,
          raw: pm_topic.posts.first.raw,
          user: pm_topic.user,
          reply_to_post_number: reply_to_post_number,
          custom_fields: {
            post_approval: true # marker to let ourselves know not to suppress notifications
          },
          skip_validations: true, # They've already gone through the validations to make the reply first
          skip_guardian: true,
        )

      else
        raise Discourse::InvalidParameters.new() # Can't do both a new topic / a reply at once
      end

      is_topic = post.is_first_post?

      # Different entry text depending on whether it was a new topic / a reply
      body = (is_topic ? SiteSetting.post_approval_response_topic : SiteSetting.post_approval_response_reply)

      # Attempt awarding badge if applicable
      if (award_badge && SiteSetting.post_approval_badge > 0)
        badge = Badge.find_by(id: SiteSetting.post_approval_badge, enabled: true)

        if badge
          # Award the badge
          BadgeGranter.grant(badge, post.user, post_id: post.id)

          # Attach a note if the user achieved a badge through this post approval request
          body += "\n\n" + SiteSetting.post_approval_response_badge
            .gsub("%BADGE%", "[#{badge.name}](#{Discourse.base_url}/badges/#{badge.id}/#{badge.slug})")
        end
      end

      # Attach a note if the user could have posted without post approval
      if could_post_on_own
        body += "\n\n" + (is_topic ? SiteSetting.post_approval_response_topic_footer : SiteSetting.post_approval_response_reply_footer)
      end

      # Format body depending on input post
      body = body.gsub("%USER%", pm_topic.user.username)
      body = body.gsub("%POST%", "#{Discourse.base_url}#{post.url}")
      if target_category
        body = body.gsub("%CATEGORY%", target_category.name)
      end

      # Send confirmation on private message
      reply = PostCreator.create(
        current_user,
        topic_id: pm_topic.id,
        raw: body,
        skip_validations: true,
      )

      # Mark confirmation as solution of private message
      if SiteSetting.solved_enabled
        DiscourseSolved.accept_answer!(reply, current_user)
      end

      # Archive the private message
      archive_message(pm_topic)

      pm_topic.reload
      pm_topic.save

      # Redirect the acting user depending on setting
      setting = current_user.custom_fields["pa_redirect_mode"]
      if setting == "pa_message"
        render json: { url: reply.url } # stay in DM
      elsif setting == "inbox"
        group_reply = Group.lookup_group(SiteSetting.post_approval_redirect_reply_group)
        if group_reply && pm_topic.topic_allowed_groups.find_by(group_id: group_reply.id)
          # go back to reply inbox if dm is addressed to reply group
          render json: { url: "#{Discourse.base_url}/g/#{SiteSetting.post_approval_redirect_reply_group}/messages/inbox" }
        else
          # go back to topic inbox otherwise
          render json: { url: "#{Discourse.base_url}/g/#{SiteSetting.post_approval_redirect_topic_group}/messages/inbox" }
        end
      else # nil, "default", "approved_post"
        render json: { url: post.url } # go to approved post
      end
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
  end

  # Routing

  PostApproval::Engine.routes.draw do
    post "/post-approval" => "post_approval#action"
  end

  Discourse::Application.routes.append do
    mount ::PostApproval::Engine, at: "/"
  end

  # Custom user fields

  User.register_custom_field_type("pa_redirect_mode", :string)
  DiscoursePluginRegistry.serialized_current_user_fields << "pa_redirect_mode"
  add_to_serializer(:current_user, :pa_redirect_mode) { object.custom_fields["pa_redirect_mode"] }
  register_editable_user_custom_field :pa_redirect_mode

  User.register_custom_field_type("pa_sort_inversed", :boolean)
  DiscoursePluginRegistry.serialized_current_user_fields << "pa_sort_inversed"
  add_to_serializer(:current_user, :pa_sort_inversed) { object.custom_fields["pa_sort_inversed"] }
  register_editable_user_custom_field :pa_sort_inversed

end
