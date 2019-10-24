require "rails_helper"

RSpec.describe "Post Approval Finish" do
  context "while enabled" do
    let(:group) { Fabricate(:group, name: "Gatekeepers") }
    let(:category) { Fabricate(:category, name: "Trash Can" )}

    let(:sage) { Fabricate(:user) }

    let(:open_category) { Fabricate(:category, name: "Engine Features") }

    before do
      Jobs.run_immediately!

      group.add(sage)
      group.save
    end

    def create_pa()
      noob = Fabricate(:user)

      bb_topic = Fabricate(
        :topic,
        user: noob,
        category: category,
      )

      bb_post = Fabricate(
        :post,
        user: noob,
        topic: bb_topic,
        raw: "I have a great idea, you've got to hear about it!",
        wiki: true,
      )

      topic = Fabricate(
        :private_message_topic,
        user: noob,
        topic_allowed_groups: [
          Fabricate(:topic_allowed_group, group: group),
        ],
      )

      post = Fabricate(
        :post,
        user: noob,
        topic: topic,
        raw: topic.url,
      )

      PostActionCreator.like(Fabricate(:user), bb_post)
      PostActionCreator.like(Fabricate(:user), bb_post)

      return {
        bb_topic: bb_topic,
        bb_post: bb_post,
        noob: noob,
        pm_topic: topic,
      }
    end

    before do
      SiteSetting.post_approval_finish_enabled = true
      SiteSetting.post_approval_finish_group = "Gatekeepers"
      SiteSetting.post_approval_finish_from_category = category.id
      SiteSetting.post_approval_finish_topic_template = "great post:%USER%/%CATEGORYNAME%/%TOPICLINK%"
    end

    context "while logged in as a sage" do
      before do
        sign_in(sage)
      end

      it "should go through the whole process when the stars align" do
        pa = create_pa()

        # Verify mock post
        expect(pa[:bb_post].wiki).to eq(true)
        expect(PostAction.where(
          post: pa[:bb_post],
          post_action_type_id: PostActionType.types[:like],
        ).count).to eq(2)

        post "/post-approval-finish.json", params: {
          bb_topic_id: pa[:bb_topic].id,
          pm_topic_id: pa[:pm_topic].id,
          category_id: open_category.id,
        }

        expect(response.status).to eq(200)

        newest_topic = Topic.last

        expect(newest_topic.posts.first.raw).to eq(pa[:bb_post].raw)
        expect(newest_topic.title).to eq(pa[:bb_topic].title)
        expect(newest_topic.posts.first.wiki).to eq(false)
        expect(newest_topic.posts.first.like_count).to eq(2)

        latest_pm_post = pa[:pm_topic].posts.last
        expect(latest_pm_post.user).to eq(sage)
        expect(latest_pm_post.raw).to start_with("great post:")
        expect(latest_pm_post.custom_fields["is_accepted_answer"]).to eq("true")

        raw = latest_pm_post.raw
        split = raw.split(":", 2)[1].split("/", 3)
        expect(split[0]).to eq(pa[:noob].username)
        expect(split[1]).to eq("Engine Features")
        expect(split[2]).to eq(newest_topic.url)

        expect(GroupArchivedMessage.where(topic: pa[:pm_topic]).exists?).to eq(true)

        PostDestroyer.destroy_stubs
        expect(pa[:bb_topic].posts.first).to eq(nil)
      end
    end

    context "while logged in as a normal user" do
      before do
        sign_in(Fabricate(:user))
      end

      it "should deny" do
        pa = create_pa()

        post "/post-approval-finish.json", params: {
          bb_topic_id: pa[:bb_topic].id,
          pm_topic_id: pa[:pm_topic].id,
          category_id: open_category.id,
        }

        expect(response.status).to eq(403)
      end
    end
  end
end
