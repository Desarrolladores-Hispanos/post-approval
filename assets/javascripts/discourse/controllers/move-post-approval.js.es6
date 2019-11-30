import { isEmpty } from "@ember/utils";
import { alias, equal } from "@ember/object/computed";
import Controller from "@ember/controller";
import ModalFunctionality from "discourse/mixins/modal-functionality";
import DiscourseURL from "discourse/lib/url";
import { default as computed } from "ember-addons/ember-computed-decorators";
import { extractError } from "discourse/lib/ajax-error";
import { ajax } from "discourse/lib/ajax";

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

    predictSelection() {
        const currentTitle = this.get("model.title");

        // TODO: use settings rather than hardcoding this?
        if (currentTitle.includes("Reply to Topic") || currentTitle.includes("Request to Reply"))
            return "existing_topic";

        return "new_topic";
    },

    predictTopicName() {
        return this.get("model.title"); // TODO: remove any prefix? (infer from settings)
    },

    predictCategoryId() {
        return null; // TODO: prepopulate from title? (infer from title + settings)
    },

    predictSelectedTopicId() {
        return null; // TODO: predict selected topic for replies? (how?)
    },

    onShow() {
        const currentName = this.get("model.title");

        this.setProperties({
            "modal.modalClass": "post-approval-modal",
            saving: false,
            selection: this.predictSelection(),
            topicName: this.predictTopicName(),
            categoryId: this.predictCategoryId(),
            selectedTopicId: this.predictSelectedTopicId(),
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
