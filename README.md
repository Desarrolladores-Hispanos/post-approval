# Plugin: `post-approval`

Implements the community post approval procedure and tools for the Roblox Developer Forum.

---

## Features

- Provides a mechanism that redirects posts made by users under a certain trust level to the Post Approval forum group inbox.

  - Redirection can be configured on a per-category level.

  - A category can be separately configured to redirect new topics and/or new replies (the settings for topics and replies are not interlinked and can be individually configured).

  - When a post is redirected, it turns into a new private message to which the user and the Post Approval forum group are added. Furthermore, a system response is sent to the message informing the user of what happened.

    - When a topic is redirected, the user is automatically brought to the DM.

    - When a reply is redirected, the user sees a notice with a link to the DM in the place of where their reply would have been posted.

    - The system response to the private message can be specified on a per-category level. For redirected replies, any occurrences of `%TOPIC%` are replaced with the name and link to the topic that the reply was initially sent to.

    - The message title consists of a prefix string (including the category name if this is a redirected topic) and the name of the topic from which the redirection took place.

- Provides functionality inside private messages for a given target group (i.e. Community Sages group, or Post Approval group) to easily accept a post approval request.

  - A button shows in DMs that brings up a modal similar to the "merge to new/existing topic" functionality available to trust level 4.

  - The modal attempts to predict several target properties:

    - **Mode:** Predicts whether the post should be accepted as a new topic or reply to an existing topic, by parsing the title of the private message.

    - **Topic > Title:** Predicted from the title of the private message. It will attempt to cut off any prefixes that are not part of the actual title.

    - **Topic > Category:** Predicted from the prefix of the title of the private message.

    - **Reply > Topic:** Uses the metadata attached to the post when the reply was redirected to predict the topic that the reply should be moved to.

  - Upon submission of the operation, a new topic / reply is created out of the contents of the first post in the private message, along with the parameters provided via the modal.

    - Additionally, a specific badge may be rewarded if configured correctly in forum settings, and the post approval team member checked the respective box on the modal.

    - A system response is sent to the private message informing the user of their successful request and any other relevant information about how the request was processed.

      - The message can be configured in forum settings. Any references to `%USER%`, `%POST%`, `%CATEGORY%` and `%BADGE%` are replaced with respectively the user's username, a link to the post, the name of the category, and the name of and link to the badge that was awarded.

    - The private message is automatically marked as solved and archived.

---

## Impact

### Community

Users have to pass through the post approval procedure before their posts are visible to other users of the forum. During this process, the post approval team will work with them to make sure their post meets category guidelines, and has enough detail and format for the target topic or category they are posting in.

By following this procedure, the quality of posts in these categories and topics is increased. This makes the forum more pleasant to engage with for users that have higher levels of experience, and sets a standard for other users to abide by when creating posts. This procedure lifts the overall quality of the forum in several ways.

This plugin enabled this procedure and also makes it easier for Post Approval team members to handle these requests quickly and efficiently.

### Internal

The amount of noise in restricted categories is reduced, because trust level 1 users (who are less likely to be familiar with forum rules and guidelines than users of higher trust levels) need to pass through post approval first before other users can see their topics and replies. This leads to a reduced workload for forum moderation and Developer Relations in general, and maintains the level of staff participation on the forum.

### Resources

There is a small overhead whenever someone creates a new post, to determine whether it should be redirected.

The cases where redirection happens should only be a small portion of posts, and so the workload needed there should be entirely non-noticeable.

Since completion of a post approval request is also an infrequent operation and does not involve too many complex queries, this is also not expected to impact the forum in any way.

### Maintenance

The badge description, per-category system response templates, as well as the forum-wide message templates for completing post approval requests should be kept up-to-date by the Post Approval team and Developer Relations.

Whenever the names of any of the involved groups change, the changes must be reflected in forum settings, otherwise the redirection mechanism will break normal posting behavior and existing post approval requests cannot be completed properly.

---

## Technical Scope

The plugin uses standard recommended functionality for extending category settings, to add the 4 settings that are used by this plugin, and ensuring they serialize properly to admin users when configuring the category. It also extends the Category class by adding extra fields that reflect the added category settings.

The plugin intervenes in the guardian that decides if a post can be moved to a specific category, and also intervenes in the method that determines whether notifications should be sent out to watchers whenever a post is edited. This is done to respectively make sure that low trust levels cannot edit existing topics into restricted categories, and to make sure notifications are not sent out when a topic or reply is about to be redirected to post approval.

The prepend mechanism that is used to intervene in these methods is a standard one, and so is unlikely to break throughout Discourse updates, with the exception of the case where the names or parameter lists of `Guardian.can_move_topic_to_category?` or `PostAlerter.after_save_post` change. Even if that happens, the forum will continue to function properly, only the functionality discussed above of this plugin will be broken.

When redirecting topics, the existing topic is turned into a private message to the post approval group using built-in Discourse API. Conversely, whenever a reply is redirected, it needs to delete the reply and start a new private message to the post approval group, because there is no API to turn a reply into a standalone private message.

Whenever replies are redirected, a custom field `pa_target_topic_id` is saved onto the private message that keeps track of where the reply was originally removed from. This allows the post approval modal to populate the target topic field based on this custom field on the private message. The custom field and its serialization are implemented using standard recommended functionality.

To find out whenever a post is created (so we can check whether it should be redirected), the Discourse

The plugin uses the integrated `DiscourseEvent.on(:post_created)` to find out whenever a new post is created anywhere on the forum, be that a topic, reply or private message. Since DiscourseEvent provides a highly explicit contract about the event, it is unlikely for the plugin functionality to break throughout Discourse updates. The event would have to be deprecated and no longer triggered in Discourse source for the plugin to stop working. In the unlikely case that happens, nothing apart from the plugin itself should break at that point, the forum will continue to function.

A rails engine is defined to create new endpoints that can be used by the plugin. Standard functionality is used to route the endpoints to the right methods in the engine. The engine provides an endpoint that is used to complete post approval requests. All input parameters are properly validated upon invocation of the endpoint, and the endpoint will reject requests from anyone that is not in the group that should have access to this functionality.

Whenever a post approval request is completed and a new topic or reply is created out of the private message, a marker (in the form of a custom field on the post) is added, which lets the notification suppression mechanism know that the post has passed through post approval, and should now properly trigger notifications for category and topic watchers, instead of suppressing the notification.

The front-end modal that is used for completing the post approval request is an edited version of the existing "merge into topic" / "merge into new topic" functionality provided by stock Discourse. The modal is adjusted so that, whenever it is opened, some parameters are predicted based on model.title and the presence of the `pa_target_topic_id` custom field discussed earlier.

On the front-end, it uses the official plugin API to insert a topic action that allows buttons on the private message to open up this modal. The button itself is placed next to the Reply button on a topic by using officially supported "plugin outlets". This is unlikely to break throughout Discourse updates.

To determine whether the button should actually be shown to the current user, the front-end checks whether the model of the current user's groups currently contains a group that is the same name as the setting that guards this functionality. This is handled via the setupComponent life cycle method of the button.

---

## Configuration

By default, the plugin will redirect posts (whenever that is appropriate) only when the user has a trust level of 1 or lower. This can be changed via `post_approval_redirect_tl_max`.

After installation, the following settings need to be adjusted:

- `post_approval_redirect_group` must be set to the group that should receive redirected topics and replies as post approval requests. It defaults to "Post_Approval" as this is the name of the group on the Roblox Developer Forum.

- `post_approval_button_group` must be set to the group that can complete post approval requests via the modal in private messages. It defaults to "Community_Sage".

- `post_approval_badge` should be set to the ID of the badge that is to be awarded whenever a post approval team member completes a request and has the "Award Post Approval badge for this post" box checked.

The system response that completes a post approval request can be adjusted by varying the text in the settings:

- `post_approval_response_topic`
- `post_approval_response_reply`
- `post_approval_response_badge`
- `post_approval_response_topic_footer`
- `post_approval_response_reply_footer`

To redirect new **topics** in a given category to post approval:

- Configure the category
- Check Settings > "Redirect new topics by low trust levels to post approval?"
- Fill out a system response in Settings > "Message to send along when redirecting new topics"
- Go to the Security tab and make sure that the trust level you are redirecting (i.e. trust level 1) has Create permissions to the category.

To redirect **replies** on topics in a given category to post approval:

- Configure the category
- Check Settings > "Redirect replies by low trust levels to post approval?"
- Fill out a system response in Settings > "Message to send along when redirecting replies"
- Go to the Security tab and make sure that the trust level you are redirecting (i.e. trust level 1) has Reply permissions to the category.
