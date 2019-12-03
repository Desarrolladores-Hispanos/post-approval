import { isEmpty } from "@ember/utils";
import { alias, equal } from "@ember/object/computed";
import Controller from "@ember/controller";
import ModalFunctionality from "discourse/mixins/modal-functionality";
import DiscourseURL from "discourse/lib/url";
import { default as computed } from "ember-addons/ember-computed-decorators";
import { extractError } from "discourse/lib/ajax-error";
import { ajax } from "discourse/lib/ajax";
import Category from "discourse/models/category";

export default Controller.extend(ModalFunctionality, {
    topicName: null,
    saving: false,
    categoryId: null,
    tags: null,
    canAddTags: alias("site.can_create_tag"),
    selectedTopicId: null,
    newTopic: equal("selection", "new_topic"),
    existingTopic: equal("selection", "existing_topic"),
    awardBadge: false,

    init() {
        this._super(...arguments);

        this.saveAttrNames = [
            "newTopic",
            "existingTopic"
        ];

        this.moveTypes = [
            "newTopic",
            "existingTopic"
        ];
    },

    @computed("saving", "selectedTopicId", "topicName")
    buttonDisabled(saving, selectedTopicId, topicName) {
        return saving || (isEmpty(selectedTopicId) && isEmpty(topicName));
    },

    @computed(
        "saving",
        "newTopic",
        "existingTopic"
    )
    buttonTitle(saving, newTopic, existingTopic) {
        if (newTopic) {
            return I18n.t("post_approval.modal.topic.title");
        } else if (existingTopic) {
            return I18n.t("post_approval.modal.reply.title");
        } else {
            return I18n.t("saving");
        }
    },

    onShow() {
        // Default parameters:

        var predictedSelection = "new_topic";
        var predictedTopicName = this.get("model.title");
        var predictedCategoryId = null;
        var predictedSelectedTopicId = null;

        // Smart prediction:

        // TODO: use settings rather than hardcoding this?
        if (predictedTopicName.includes("Reply to Topic")
         || predictedTopicName.includes("Request to Reply")
         || predictedTopicName.includes(Discourse.SiteSettings.post_approval_redirect_reply_prefix))
            predictedSelection = "existing_topic";

        const category = Category.list().forEach(
            c => {
                const prefix = Discourse.SiteSettings.post_approval_redirect_topic_prefix.replace("%s", c.get("name"));
                if (predictedTopicName.startsWith(prefix)) {
                    predictedTopicName = predictedTopicName.slice(prefix.length);
                    predictedCategoryId = c.get("id");
                }
            }
        );

        // TODO: predict selected topic for replies? (how?)

        // Feed predicted properties to modal:

        this.setProperties({
            "modal.modalClass": "post-approval-modal",
            saving: false,
            selection: predictedSelection,
            topicName: predictedTopicName,
            categoryId: predictedCategoryId,
            selectedTopicId: predictedSelectedTopicId,
            tags: null
        });
    },

    actions: {
        completePostApproval() {
            this.moveTypes.forEach(type => {
                if (this.get(type)) {
                    this.send("movePostTo", type);
                }
            });
        },

        movePostTo(type) {
            this.set("saving", true);
            const topicId = this.get("model.id");
            let options;

            if (type === "existingTopic") {
                options = {
                    pm_topic_id: topicId,
                    target_topic_id: this.selectedTopicId,
                    award_badge: this.awardBadge
                };
            } else if (type === "newTopic") {
                options = {
                    pm_topic_id: topicId,
                    title: this.topicName,
                    target_category_id: this.categoryId,
                    tags: this.tags,
                    award_badge: this.awardBadge
                };
            }

            const promise = ajax("/post-approval", {
                data: options,
                cache: false,
                type: "POST"
            });

            promise
                .then(result => {
                    this.send("closeModal");
                    DiscourseURL.routeTo(result.url);
                })
                .catch(xhr => {
                    if (type === "existingTopic")
                        this.flash(extractError(xhr, I18n.t("post_approval.modal.reply.error")));
                    else
                        this.flash(extractError(xhr, I18n.t("post_approval.modal.topic.error")));
                })
                .finally(() => {
                    this.set("saving", false);
                });

            return false;
        }
    }
});
