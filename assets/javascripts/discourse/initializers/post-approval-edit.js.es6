import { withPluginApi } from 'discourse/lib/plugin-api';
import showModal from "discourse/lib/show-modal";

export default {
    name: 'post-approval-edits',

    initialize() {
        withPluginApi('0.8.13', api => {

            api.modifyClass('route:topic', {
                actions: {
                    movePostApproval() {
                        showModal("move-post-approval", {
                            model: this.modelFor("topic"),
                            title: "post_approval.modal.title"
                        });
                    },
                }
            });

        });
    }
};
