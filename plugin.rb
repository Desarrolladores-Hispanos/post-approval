# name: post-approval-finish
# version: 0.0.1
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

      bb_topic = Topic.find_by(id: params[:bb_topic_id])
      pm_topic = Topic.find_by(id: params[:pm_topic_id], archetype: Archetype.private_message)
      category = Category.find_by(id: params[:category_id])

      raise Discourse::InvalidParameters.new(:bb_topic_id) unless bb_topic
      raise Discourse::InvalidParameters.new(:pm_topic_id) unless pm_topic
      raise Discourse::InvalidParameters.new(:category_id) unless category

      post = PostCreator.create(
        bb_topic.user,
        category: category.id,
        title: bb_topic.title,
        raw: bb_topic.posts.first.raw,
        user: bb_topic.user,
        skip_validations: true, # They've already gone through the validations to make the topic first
      )

      PostAction.where(
        post: bb_topic.posts.first,
        post_action_type_id: PostActionType.types[:like],
      ).each do |action|
        PostActionCreator.create(action.user, post, :like)
      end

      # Confirmation message
      post = PostCreator.create(
        current_user,
        topic_id: pm_topic.id,
        raw: SiteSetting.post_approval_finish_topic_template
          .gsub("%USER%", bb_topic.user.username)
          .gsub("%CATEGORYNAME%", category.name)
          .gsub("%TOPICLINK%", post.topic.url),
        skip_validations: true,
      )

      DiscourseSolved.accept_answer!(post, current_user)

      archive_message(post.topic)
      post.topic.reload
      post.topic.save

      PostDestroyer.new(Discourse.system_user, bb_topic.posts.first).destroy

      render json: success_json
    end

    # Copies and pasted from TopicsController.
    # Discourse does not provide a method to archive the message.
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

  PostApprovalFinish::Engine.routes.draw do
    post "/post-approval-finish" => "post_approval_finish#action"
  end

  Discourse::Application.routes.append do
    mount ::PostApprovalFinish::Engine, at: "/"
  end
end
