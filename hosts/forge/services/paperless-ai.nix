# hosts/forge/services/paperless-ai.nix
#
# Host-specific configuration for Paperless-AI on 'forge'.
# Paperless-AI provides AI-powered document tagging for Paperless-ngx.
#
# Integration:
# - Connects to local Paperless-ngx instance (port 28981)
# - Uses Anthropic directly through its OpenAI-compatible API
# - Internal-only access via caddySecurity.home (PocketID SSO)
#
{ config, lib, pkgs, ... }:
let
  forgeDefaults = import ../lib/defaults.nix { inherit config lib; };
  inherit (config.networking) domain;
  serviceDomain = "paperless-ai.${domain}";
  dataset = "tank/services/paperless-ai";
  dataDir = "/var/lib/paperless-ai";
  listenPort = 3001;
  serviceEnabled = config.modules.services.paperless-ai.enable or false;
  managedDocumentTypes = [
    "Performance Work Statement"
    "Request for Information"
    "Invoice"
    "Receipt"
    "Account Statement"
    "Official Notice"
    "Performance Work Statement / Contract Statement of Work"
    "Request for Information (RFI)"
    "Credit Card Statement"
    "Tax Bill"
    "Tax Form"
    "Permit"
    "Explanation of Benefits"
  ];
  customFields = [
    { value = "finance:tax-year"; data_type = "integer"; }
    { value = "finance:account-last4"; data_type = "string"; }
    { value = "finance:statement-period"; data_type = "string"; }
    { value = "finance:amount-due"; data_type = "monetary"; currency = "USD"; }
    { value = "workflow:suggested-tags"; data_type = "longtext"; }
    { value = "workflow:suggested-document-type"; data_type = "string"; }
  ];
  savedViews = [
    { name = "Finance / Statements"; tag = "finance:statement"; dashboard = false; }
    { name = "Finance / Taxes"; tag = "finance:tax"; dashboard = false; }
    { name = "Finance / Paystubs"; tag = "finance:paystub"; dashboard = false; }
    { name = "Finance / Insurance"; tag = "finance:insurance"; dashboard = false; }
    { name = "Finance / Invoices"; tag = "finance:invoice"; dashboard = false; }
    { name = "Finance / Receipts"; tag = "finance:receipt"; dashboard = false; }
    { name = "Finance / Loans"; tag = "finance:loan"; dashboard = false; }
    { name = "Finance / Investments"; tag = "finance:investment"; dashboard = false; }
    { name = "Workflow / Needs Review"; tag = "workflow:needs-review"; dashboard = true; }
    { name = "Workflow / Reprocess Queue"; tag = "workflow:reprocess"; dashboard = false; }
  ];
  bootstrapScript = pkgs.writeText "paperless-finance-bootstrap.py" ''
    import json

    from django.contrib.auth import get_user_model
    from documents.models import CustomField
    from documents.models import SavedView
    from documents.models import SavedViewFilterRule
    from documents.models import Tag
    from documents.models import Workflow
    from documents.models import WorkflowAction
    from documents.models import WorkflowTrigger

    custom_fields = json.loads(${builtins.toJSON (builtins.toJSON customFields)})
    saved_views = json.loads(${builtins.toJSON (builtins.toJSON savedViews)})

    fields = {}
    for definition in custom_fields:
      extra_data = {}
      if definition.get("currency"):
        extra_data["default_currency"] = definition["currency"]
      field, _ = CustomField.objects.update_or_create(
        name=definition["value"],
        defaults={
          "data_type": definition["data_type"],
          "extra_data": extra_data,
        },
      )
      fields[field.name] = field

    User = get_user_model()
    owner = (
      User.objects.filter(username="ryan@ryanholt.net").first()
      or User.objects.filter(email="ryan@ryanholt.net").first()
    )
    if owner is None:
      raise RuntimeError("Paperless admin user ryan@ryanholt.net does not exist")

    for definition in saved_views:
      tag = Tag.objects.get(name=definition["tag"])
      display_fields = [
        "title",
        "created",
        "correspondent",
        "documenttype",
        "tag",
        "asn",
      ]
      if definition["tag"] == "workflow:needs-review":
        display_fields.extend([
          f"custom_field_{fields['workflow:suggested-tags'].id}",
          f"custom_field_{fields['workflow:suggested-document-type'].id}",
        ])
      view, _ = SavedView.objects.update_or_create(
        owner=owner,
        name=definition["name"],
        defaults={
          "show_on_dashboard": definition["dashboard"],
          "show_in_sidebar": True,
          "sort_field": "created",
          "sort_reverse": True,
          "page_size": 50,
          "display_mode": "table",
          "display_fields": display_fields,
        },
      )
      SavedViewFilterRule.objects.filter(saved_view=view).delete()
      SavedViewFilterRule.objects.create(
        saved_view=view,
        rule_type=6,
        value=str(tag.id),
      )

    workflow, _ = Workflow.objects.update_or_create(
      name="New documents await Paperless-AI review",
      defaults={"enabled": True, "order": 10},
    )
    old_triggers = list(workflow.triggers.all())
    old_actions = list(workflow.actions.all())
    workflow.triggers.clear()
    workflow.actions.clear()
    WorkflowTrigger.objects.filter(pk__in=[item.pk for item in old_triggers]).delete()
    WorkflowAction.objects.filter(pk__in=[item.pk for item in old_actions]).delete()

    trigger = WorkflowTrigger.objects.create(
      type=WorkflowTrigger.WorkflowTriggerType.DOCUMENT_ADDED,
      matching_algorithm=WorkflowTrigger.WorkflowTriggerMatching.NONE,
      match="",
    )
    action = WorkflowAction.objects.create(
      type=WorkflowAction.WorkflowActionType.ASSIGNMENT,
    )
    action.assign_tags.set([Tag.objects.get(name="workflow:needs-review")])
    workflow.triggers.set([trigger])
    workflow.actions.set([action])
  '';
in
{
  config = lib.mkMerge [
    # =========================================================================
    # Service Configuration
    # =========================================================================
    {
      modules.services.paperless-ai = {
        enable = true;
        port = listenPort;

        # Storage
        dataDir = dataDir;

        # Use same user/group as paperless-ngx for shared permissions
        user = "paperless";
        group = "paperless";

        # =====================================================================
        # Paperless-ngx Integration
        # =====================================================================
        paperless = {
          # Reach Paperless through Caddy on the shared container bridge.
          apiUrl = "https://paperless.${domain}/api";
          tokenFile = config.sops.secrets."paperless-ai/paperless_token".path;
          # Paperless-ngx web UI username (must match the API token owner)
          username = "paperless-ai";
        };

        # =====================================================================
        # LLM Configuration (direct Anthropic API)
        # =====================================================================
        llm = {
          # The module maps this to Paperless-AI's custom OpenAI-compatible
          # provider using Anthropic's official compatibility endpoint.
          provider = "anthropic";
          model = "claude-haiku-4-5-20251001";
          apiKeyFile = config.sops.secrets."paperless-ai/llm_api_key".path;
        };

        # =====================================================================
        # API Authentication
        # =====================================================================
        apiKeyFile = config.sops.secrets."paperless-ai/api_key".path;

        # =====================================================================
        # Scanning Configuration
        # =====================================================================
        scan = {
          automaticProcessing = false;
          interval = "*/30 * * * *"; # Every 30 minutes
          addAiProcessedTag = true;
          aiProcessedTagName = "workflow:ai-processed";
          useExistingData = true;
        };

        # Controlled vocabulary shared with downstream document consumers.
        # Unknown tags are discarded, and the reconciler removes legacy test tags.
        tags = {
          restrictToExisting = true;
          managed = [
            "finance:statement"
            "finance:tax"
            "finance:paystub"
            "finance:insurance"
            "finance:invoice"
            "finance:receipt"
            "finance:loan"
            "finance:investment"
            "property:permit"
            "workflow:needs-review"
            "workflow:ai-processed"
            "workflow:reprocess"
          ];
          # Required tags are seeded, but accepted suggestions created in the UI persist.
          pruneUnmanaged = false;
          reconcileOnCalendar = "daily";
        };

        documentTypes = {
          restrictToExisting = true;
          managed = managedDocumentTypes;
        };

        aiFunctions.customFields = true;
        inherit customFields;

        systemPrompt = ''
          Classify each document using only this controlled Paperless taxonomy:
          %RESTRICTED_TAGS%

          Tag definitions:
          - finance:statement: Periodic bank, credit-card, brokerage, retirement, or other account statements.
          - finance:tax: Tax returns, W-2/1099 forms, tax bills, assessments, and tax authority notices.
          - finance:paystub: Payroll statements, payslips, and earnings statements.
          - finance:insurance: Policies, declarations, premium notices, claims, explanations of benefits, and insurer claim-payment vouchers or reimbursement checks.
          - finance:invoice: Requests for payment that have not yet been paid.
          - finance:receipt: Merchant or vendor proof of a completed purchase or bill payment; excludes insurance claim payments, reimbursements, and EOB payment vouchers.
          - finance:loan: Loan agreements, mortgage documents, payment schedules, and lending notices.
          - finance:investment: Trade confirmations, portfolio reports, and investment or retirement-plan documents that are not periodic statements.
          - property:permit: Government-issued building, septic, environmental health, occupancy, or similar property permits, approvals, and completion certificates.
          - workflow:needs-review: The document does not confidently fit a finance category above.
          - workflow:ai-processed: Reserved for Paperless-AI; never select it yourself.
          - workflow:reprocess: Reserved for requesting another AI pass; never select it yourself.

          Custom fields:
          - finance:tax-year: Four-digit tax year when explicitly present.
          - finance:account-last4: Last four account digits when explicitly present; never store a full account number.
          - finance:statement-period: Statement month or date range in ISO-style form.
          - finance:amount-due: Numeric amount currently requested for payment, without a currency symbol. Never use income, interest paid, principal balance, tax withheld, reimbursement, or another historical amount.
          - workflow:suggested-tags: When the existing taxonomy is insufficient, propose up to three lowercase namespaced tag identifiers with a brief reason for each.
          - workflow:suggested-document-type: When no allowed document type fits, propose one concise title-cased document type name.

          Allowed document types:
          ${lib.concatMapStringsSep "\n" (name: "- ${name}") managedDocumentTypes}

          Rules:
          - Return exact tag identifiers from the list above; never translate, alter, or invent tag names.
          - Tags present in the existing-tag list without a definition above are user-approved; infer their meaning from the identifier and use them when they clearly match.
          - Never propose an identifier in workflow:suggested-tags if that tag already exists in the existing-tag list.
          - Select one primary existing tag and a second only when the document clearly serves both purposes.
          - Classify the packet by its primary purpose, not an attachment. Any EOB, claim explanation, or insurer payment voucher remains finance:insurance when it includes a check, reimbursement, or amount paid.
          - Use the exact document type Explanation of Benefits for every EOB, claim explanation, insurer payment voucher, or EOB/check packet.
          - Use the exact document type Receipt for merchant or vendor receipts, paid-in-full orders, and proof of completed payment.
          - Use the exact document type Tax Form for W-2, W-3, 1098, 1099, 3921, 3922, and similar tax-reporting forms.
          - Use the exact document type Permit for property permits, permit applications, approvals, inspections, and completion certificates.
          - Set document_type to an exact allowed document type. If none fits, set document_type to null, populate workflow:suggested-document-type, and include workflow:needs-review.
          - If no existing tag fits, return only workflow:needs-review and populate workflow:suggested-tags.
          - If classification confidence is low, return only workflow:needs-review; suggestions are optional.
          - Never place a proposed tag in the tags array until it exists in Paperless.
          - Controlled tag identifiers remain in English regardless of the document language.
          - Create a concise title, identify the shortest useful correspondent name, extract the document date, and determine a precise document type and language.
        '';

        # =====================================================================
        # Reverse Proxy with PocketID SSO
        # =====================================================================
        # PocketID handles authentication, then Caddy injects the x-api-key
        # header to bypass paperless-ai's internal auth (via API_KEY env var)
        reverseProxy = {
          enable = true;
          hostName = serviceDomain;
          backend = {
            host = "127.0.0.1";
            port = listenPort;
          };
          # PocketID SSO - requires "home" group membership
          caddySecurity = forgeDefaults.caddySecurity.home;
          # Inject the API key header to bypass internal paperless-ai auth
          reverseProxyBlock = ''
            header_up x-api-key {$PAPERLESS_AI_API_KEY}
          '';
        };

        # =====================================================================
        # Resource Limits
        # =====================================================================
        # Python/AI service with 6 gunicorn workers
        # Each worker can use 300-500MB during document processing
        resources = {
          memory = "2G";
          memoryReservation = "1G";
          cpus = "2.0";
        };

        # =====================================================================
        # Backup & DR
        # =====================================================================
        backup = forgeDefaults.mkBackupWithTags "paperless-ai" [ "documents" "paperless-ai" "forge" ];
        preseed = forgeDefaults.mkPreseed [ "syncoid" "local" ];

        # Notifications
        notifications.enable = true;
      };
    }

    # =========================================================================
    # Host-level Resources (guarded by service enable)
    # =========================================================================
    (lib.mkIf serviceEnabled {
      virtualisation.oci-containers.containers."paperless-ai".extraOptions = [
        "--network=${forgeDefaults.podmanNetwork}"
        "--add-host=paperless.${domain}:10.89.0.1"
      ];

      systemd.services.podman-paperless-ai = {
        requires = [
          "podman-network-${forgeDefaults.podmanNetwork}.service"
          "paperless-finance-bootstrap.service"
        ];
        after = [
          "podman-network-${forgeDefaults.podmanNetwork}.service"
          "paperless-finance-bootstrap.service"
          "caddy.service"
          "paperless-web.service"
        ];
        wants = [ "caddy.service" "paperless-web.service" ];
        serviceConfig.LogFilterPatterns = [ "~.*apiKey:.*" ];
      };

      systemd.services.paperless-finance-bootstrap = {
        description = "Bootstrap Paperless finance fields, views, and workflows";
        before = [ "podman-paperless-ai.service" ];
        after = [
          "paperless-ai-taxonomy.service"
          "paperless-scheduler.service"
        ];
        requires = [
          "paperless-ai-taxonomy.service"
          "paperless-scheduler.service"
        ];

        serviceConfig = {
          Type = "oneshot";
          User = "paperless";
          Group = "paperless";
          NoNewPrivileges = true;
          PrivateDevices = true;
          PrivateTmp = true;
          ProtectHome = true;
          ProtectSystem = "strict";
          ReadWritePaths = [ "/var/lib/paperless" ];
        };

        script = ''
          set -euo pipefail
          ${config.services.paperless.manage}/bin/paperless-manage shell < ${bootstrapScript}
        '';
      };

      systemd.services.paperless-ai-reprocess = {
        description = "Dispatch one pending Paperless document to Paperless-AI";
        after = [
          "paperless-finance-bootstrap.service"
          "podman-paperless-ai.service"
        ];
        wants = [ "podman-paperless-ai.service" ];
        requires = [ "paperless-finance-bootstrap.service" ];

        serviceConfig = {
          Type = "oneshot";
          User = "paperless";
          Group = "paperless";
          LoadCredential = [
            "paperless_token:${config.sops.secrets."paperless-ai/paperless_token".path}"
            "api_key:${config.sops.secrets."paperless-ai/api_key".path}"
          ];
          NoNewPrivileges = true;
          PrivateDevices = true;
          PrivateTmp = true;
          ProtectHome = true;
          ProtectSystem = "strict";
          TimeoutStartSec = "30m";
          Restart = "on-failure";
          RestartSec = "2m";
        };

        script = ''
          set -euo pipefail

          paperless_api="http://127.0.0.1:28981/api"
          paperless_ai="http://127.0.0.1:${toString listenPort}"
          paperless_token="$(${pkgs.coreutils}/bin/cat "$CREDENTIALS_DIRECTORY/paperless_token")"
          api_key="$(${pkgs.coreutils}/bin/cat "$CREDENTIALS_DIRECTORY/api_key")"
          auth=(--header "Authorization: Token $paperless_token")

          get_tag_id() {
            ${pkgs.curl}/bin/curl --fail --silent --show-error --max-time 15 \
              "''${auth[@]}" --get --data-urlencode "name__iexact=$1" \
              "$paperless_api/tags/" | ${pkgs.jq}/bin/jq --raw-output '.results[0].id // empty'
          }

          reprocess_id="$(get_tag_id 'workflow:reprocess')"
          processed_id="$(get_tag_id 'workflow:ai-processed')"
          review_id="$(get_tag_id 'workflow:needs-review')"
          [[ -n "$reprocess_id" && -n "$processed_id" && -n "$review_id" ]]

          tags_json="$(${pkgs.curl}/bin/curl --fail --silent --show-error --max-time 30 \
            "''${auth[@]}" "$paperless_api/tags/?page_size=1000")"
          tag_lookup="$(${pkgs.jq}/bin/jq --compact-output \
            'reduce .results[] as $tag ({}; .[($tag.name | ascii_downcase)] = $tag.id)' \
            <<< "$tags_json")"
          property_permit_tag_id="$(${pkgs.jq}/bin/jq --raw-output \
            '.["property:permit"] // empty' <<< "$tag_lookup")"
          workflow_tag_ids="$(${pkgs.jq}/bin/jq --compact-output \
            '[.results[] | select(.name | startswith("workflow:")) | .id]' \
            <<< "$tags_json")"

          document_types_json="$(${pkgs.curl}/bin/curl --fail --silent --show-error --max-time 30 \
            "''${auth[@]}" "$paperless_api/document_types/?page_size=1000")"
          document_type_lookup="$(${pkgs.jq}/bin/jq --compact-output \
            'reduce .results[] as $type ({}; .[($type.name | ascii_downcase)] = {id: $type.id, name: $type.name})' \
            <<< "$document_types_json")"
          managed_document_types='${builtins.toJSON managedDocumentTypes}'
          managed_document_type_ids="$(${pkgs.jq}/bin/jq --compact-output \
            --argjson managed "$managed_document_types" \
            '[$managed[] as $name | .[$name | ascii_downcase].id // empty]' \
            <<< "$document_type_lookup")"
          eob_document_type_id="$(${pkgs.jq}/bin/jq --raw-output \
            '.["explanation of benefits"].id // empty' <<< "$document_type_lookup")"

          suggested_tags_field_id="$(${pkgs.curl}/bin/curl --fail --silent --show-error --max-time 15 \
            "''${auth[@]}" --get --data-urlencode 'name__iexact=workflow:suggested-tags' \
            "$paperless_api/custom_fields/" | ${pkgs.jq}/bin/jq --raw-output '.results[0].id // empty')"
          suggested_type_field_id="$(${pkgs.curl}/bin/curl --fail --silent --show-error --max-time 15 \
            "''${auth[@]}" --get --data-urlencode 'name__iexact=workflow:suggested-document-type' \
            "$paperless_api/custom_fields/" | ${pkgs.jq}/bin/jq --raw-output '.results[0].id // empty')"
          amount_due_field_id="$(${pkgs.curl}/bin/curl --fail --silent --show-error --max-time 15 \
            "''${auth[@]}" --get --data-urlencode 'name__iexact=finance:amount-due' \
            "$paperless_api/custom_fields/" | ${pkgs.jq}/bin/jq --raw-output '.results[0].id // empty')"
          finance_custom_field_ids="$(${pkgs.curl}/bin/curl --fail --silent --show-error --max-time 15 \
            "''${auth[@]}" "$paperless_api/custom_fields/?page_size=1000" \
            | ${pkgs.jq}/bin/jq --compact-output \
              '[.results[] | select(.name | startswith("finance:")) | .id]')"
          [[ -n "$property_permit_tag_id" && -n "$eob_document_type_id" && -n "$amount_due_field_id" ]]

          stale_reviews="$(${pkgs.curl}/bin/curl --fail --silent --show-error --max-time 30 \
            "''${auth[@]}" --get \
            --data-urlencode "tags__id__all=$review_id" \
            --data-urlencode 'page_size=1000' \
            --data-urlencode 'fields=id,tags,document_type,custom_fields' \
            "$paperless_api/documents/")"
          cleanup_count=0
          while IFS= read -r document; do
            if ! ${pkgs.jq}/bin/jq --exit-status \
              --argjson processed "$processed_id" \
              --argjson workflow "$workflow_tag_ids" \
              --argjson managed_types "$managed_document_type_ids" \
              --argjson suggested_tags "''${suggested_tags_field_id:-null}" \
              --argjson suggested_type "''${suggested_type_field_id:-null}" \
              '(.tags | index($processed)) != null
              and ([.tags[] as $tag | select($workflow | index($tag) | not) | $tag] | length > 0)
              and (.document_type as $type | ($managed_types | index($type)) != null)
              and ([.custom_fields[]? | select(
                (($suggested_tags != null and .field == $suggested_tags)
                  or ($suggested_type != null and .field == $suggested_type))
                and ((.value // "") | length > 0)
              )] | length == 0)' \
              <<< "$document" >/dev/null; then
              continue
            fi

            document_id="$(${pkgs.jq}/bin/jq --raw-output '.id' <<< "$document")"
            payload="$(${pkgs.jq}/bin/jq --compact-output \
              --argjson review "$review_id" \
              '{tags: [.tags[] | select(. != $review)]}' <<< "$document")"
            ${pkgs.curl}/bin/curl --fail --silent --show-error --max-time 30 \
              --request PATCH \
              "''${auth[@]}" \
              --header 'Content-Type: application/json' \
              --data "$payload" \
              "$paperless_api/documents/$document_id/" >/dev/null
            ((cleanup_count += 1))
          done < <(${pkgs.jq}/bin/jq --compact-output '.results[]' <<< "$stale_reviews")
          echo "Cleared stale review tags from $cleanup_count classified document(s)"

          documents="$(${pkgs.curl}/bin/curl --fail --silent --show-error --max-time 30 \
            "''${auth[@]}" --get \
            --data-urlencode "tags__id__all=$reprocess_id" \
            --data-urlencode 'page_size=1' \
            --data-urlencode 'fields=id,tags,document_type,custom_fields' \
            "$paperless_api/documents/")"
          document="$(${pkgs.jq}/bin/jq --compact-output '.results[0] // empty' <<< "$documents")"

          if [[ -z "$document" ]]; then
            documents="$(${pkgs.curl}/bin/curl --fail --silent --show-error --max-time 30 \
              "''${auth[@]}" --get \
              --data-urlencode "tags__id__all=$review_id" \
              --data-urlencode 'page_size=1000' \
              --data-urlencode 'fields=id,tags,document_type,custom_fields' \
              "$paperless_api/documents/")"
            document="$(${pkgs.jq}/bin/jq --compact-output \
              --argjson processed "$processed_id" \
              --argjson reprocess "$reprocess_id" \
              '[.results[] | select(
                (.tags | index($processed) | not)
                and (.tags | index($reprocess) | not)
              )][0] // empty' <<< "$documents")"
          fi

          if [[ -z "$document" ]]; then
            echo "No documents pending Paperless-AI processing"
            exit 0
          fi

          document_id="$(${pkgs.jq}/bin/jq --raw-output '.id' <<< "$document")"
          original_document_type_id="$(${pkgs.jq}/bin/jq --compact-output '.document_type // null' <<< "$document")"
          original_custom_fields="$(${pkgs.jq}/bin/jq --compact-output \
            --argjson amount_due "$amount_due_field_id" \
            '[.custom_fields[]? | select(
              .field != $amount_due or (((.value | tonumber?) // 0) > 0)
            )]' <<< "$document")"
          accepted_tags="$(${pkgs.jq}/bin/jq --compact-output \
            --argjson reprocess "$reprocess_id" \
            --argjson processed "$processed_id" \
            --argjson review "$review_id" \
            --argjson suggested "''${suggested_tags_field_id:-null}" \
            --argjson lookup "$tag_lookup" \
            '(
              .custom_fields[]?
              | select($suggested != null and .field == $suggested)
              | .value
            ) // "" as $suggestions
            | ([
                $suggestions
                | scan("(?i)(?:^|[;\\n])\\s*([a-z0-9][a-z0-9_-]*:[a-z0-9][a-z0-9._-]*)\\s*(?:-|$)")
                | .[0]
                | ascii_downcase
                | select(startswith("workflow:") | not)
                | $lookup[.] // empty
              ]) as $promoted
            | ([
                .tags[]
                | select(. != $reprocess and . != $processed and . != $review)
              ] + $promoted | unique)' <<< "$document")"

          suggested_document_type="$(${pkgs.jq}/bin/jq --raw-output \
            --argjson suggested "''${suggested_type_field_id:-null}" \
            '([.custom_fields[]?
              | select($suggested != null and .field == $suggested)
              | .value
              | select(. != null and . != "")][0]) // ""' <<< "$document")"
          accepted_document_type_id=""
          if ${pkgs.jq}/bin/jq --exit-status --arg name "$suggested_document_type" \
            '(map(ascii_downcase) | index($name | ascii_downcase)) != null' \
            <<< "$managed_document_types" >/dev/null; then
            accepted_document_type_id="$(${pkgs.jq}/bin/jq --raw-output \
              --arg name "$suggested_document_type" \
              '.[$name | ascii_downcase].id // empty' <<< "$document_type_lookup")"
          fi
          if [[ -z "$accepted_document_type_id" \
            && "$original_document_type_id" == "$eob_document_type_id" ]]; then
            accepted_document_type_id="$eob_document_type_id"
          fi

          ${pkgs.curl}/bin/curl --fail --silent --show-error --max-time 30 \
            --request POST \
            --header "x-api-key: $api_key" \
            --header 'Content-Type: application/json' \
            --data "$(${pkgs.jq}/bin/jq --null-input --compact-output --argjson id "$document_id" '{ids: [$id]}')" \
            "$paperless_ai/api/reset-documents" >/dev/null

          payload="$(${pkgs.jq}/bin/jq --compact-output \
            --argjson suggested_tags "''${suggested_tags_field_id:-null}" \
            --argjson suggested_type "''${suggested_type_field_id:-null}" \
            --argjson review "$review_id" \
            --argjson accepted "$accepted_tags" \
            --argjson accepted_type "''${accepted_document_type_id:-null}" \
            --argjson property_permit "$property_permit_tag_id" \
            --argjson finance_fields "$finance_custom_field_ids" \
            --argjson eob_type "$eob_document_type_id" \
            --argjson amount_due "$amount_due_field_id" \
            '{
              tags: ($accepted + [$review] | unique),
              document_type: $accepted_type,
              custom_fields: [
                .custom_fields[]? | .field as $field | select(
                  ($suggested_tags == null or .field != $suggested_tags)
                  and ($suggested_type == null or .field != $suggested_type)
                  and ($accepted_type != $eob_type or .field != $amount_due)
                  and (.field != $amount_due or (((.value | tonumber?) // 0) > 0))
                  and (($accepted | index($property_permit)) == null
                    or ($finance_fields | index($field)) == null)
                )
              ]
            }' \
            <<< "$document")"
          ${pkgs.curl}/bin/curl --fail --silent --show-error --max-time 30 \
            --request PATCH \
            "''${auth[@]}" \
            --header 'Content-Type: application/json' \
            --data "$payload" \
            "$paperless_api/documents/$document_id/" >/dev/null

          ${pkgs.curl}/bin/curl --fail --silent --show-error --max-time 1800 \
            --request POST \
            --header "x-api-key: $api_key" \
            --header 'Content-Type: application/json' \
            --data "$(${pkgs.jq}/bin/jq --null-input --compact-output \
              --arg url "${config.modules.services.paperless-ai.paperless.apiUrl}/documents/$document_id/" \
              '{url: $url}')" \
            "$paperless_ai/api/webhook/document" >/dev/null

          document="$(${pkgs.curl}/bin/curl --fail --silent --show-error --max-time 30 \
            "''${auth[@]}" "$paperless_api/documents/$document_id/")"
          if ${pkgs.jq}/bin/jq --exit-status --argjson processed "$processed_id" \
            '(.tags | index($processed)) != null' <<< "$document" >/dev/null; then
            current_document_type_id="$(${pkgs.jq}/bin/jq --raw-output '.document_type // empty' <<< "$document")"
            current_document_type_name=""
            current_document_type_json=""
            if [[ -n "$current_document_type_id" ]]; then
              current_document_type_json="$(${pkgs.curl}/bin/curl --fail --silent --show-error --max-time 30 \
                "''${auth[@]}" "$paperless_api/document_types/$current_document_type_id/")"
              current_document_type_name="$(${pkgs.jq}/bin/jq --raw-output '.name' \
                <<< "$current_document_type_json")"
            fi

            document_type_allowed=false
            final_document_type_id="null"
            unmanaged_document_type_id=""
            type_suggestion="$(${pkgs.jq}/bin/jq --raw-output \
              --argjson suggested "''${suggested_type_field_id:-null}" \
              '([.custom_fields[]?
                | select($suggested != null and .field == $suggested)
                | .value
                | select(. != null and . != "")][0]) // ""' <<< "$document")"

            if [[ -n "$accepted_document_type_id" ]]; then
              document_type_allowed=true
              final_document_type_id="$accepted_document_type_id"
              type_suggestion=""
            elif [[ -n "$type_suggestion" ]]; then
              if [[ -n "$current_document_type_name" ]] \
                && ! ${pkgs.jq}/bin/jq --exit-status --arg name "$current_document_type_name" \
                  '(map(ascii_downcase) | index($name | ascii_downcase)) != null' \
                  <<< "$managed_document_types" >/dev/null; then
                unmanaged_document_type_id="$current_document_type_id"
              fi
            elif [[ -n "$current_document_type_name" ]] \
              && ${pkgs.jq}/bin/jq --exit-status --arg name "$current_document_type_name" \
                '(map(ascii_downcase) | index($name | ascii_downcase)) != null' \
                <<< "$managed_document_types" >/dev/null; then
              document_type_allowed=true
              final_document_type_id="$current_document_type_id"
              type_suggestion=""
            else
              if [[ -n "$current_document_type_name" ]]; then
                type_suggestion="$current_document_type_name"
                unmanaged_document_type_id="$current_document_type_id"
              fi
            fi

            payload="$(${pkgs.jq}/bin/jq --compact-output \
              --argjson reprocess "$reprocess_id" \
              --argjson processed "$processed_id" \
              --argjson review "$review_id" \
              --argjson accepted "$accepted_tags" \
              --argjson type_allowed "$document_type_allowed" \
              --argjson document_type "$final_document_type_id" \
              --argjson suggested_type "''${suggested_type_field_id:-null}" \
              --argjson property_permit "$property_permit_tag_id" \
              --argjson finance_fields "$finance_custom_field_ids" \
              --argjson eob_type "$eob_document_type_id" \
              --argjson amount_due "$amount_due_field_id" \
              --arg type_suggestion "$type_suggestion" \
              '([.tags[] | select(. != $reprocess)] + $accepted | unique) as $merged
              | ($merged | map(select(. != $processed and . != $review)) | length) as $classified
              | {
                  tags: (
                    if $classified > 0 and $type_allowed
                    then $merged | map(select(. != $review))
                    else ($merged + [$review] | unique)
                    end
                  ),
                  document_type: $document_type,
                  custom_fields: (
                    [.custom_fields[]? | .field as $field | select(
                      $suggested_type == null or .field != $suggested_type
                    ) | select(
                      $document_type != $eob_type or .field != $amount_due
                    ) | select(
                      .field != $amount_due or (((.value | tonumber?) // 0) > 0)
                    ) | select(
                      ($merged | index($property_permit)) == null
                      or ($finance_fields | index($field)) == null
                    )]
                    + (if $suggested_type != null and $type_suggestion != ""
                      then [{field: $suggested_type, value: $type_suggestion}]
                      else []
                      end)
                  )
                }' <<< "$document")"
            result="processed"
          else
            payload="$(${pkgs.jq}/bin/jq --compact-output \
              --argjson reprocess "$reprocess_id" \
              --argjson review "$review_id" \
              --argjson original_type "$original_document_type_id" \
              --argjson original_custom_fields "$original_custom_fields" \
              '{
                tags: (.tags + [$review, $reprocess] | unique),
                document_type: $original_type,
                custom_fields: $original_custom_fields
              }' <<< "$document")"
            result="failed"
          fi

          ${pkgs.curl}/bin/curl --fail --silent --show-error --max-time 30 \
            --request PATCH \
            "''${auth[@]}" \
            --header 'Content-Type: application/json' \
            --data "$payload" \
            "$paperless_api/documents/$document_id/" >/dev/null

          if [[ -n "''${unmanaged_document_type_id:-}" ]]; then
            document_type="$(${pkgs.curl}/bin/curl --fail --silent --show-error --max-time 30 \
              "''${auth[@]}" "$paperless_api/document_types/$unmanaged_document_type_id/")"
            if [[ "$(${pkgs.jq}/bin/jq --raw-output '.document_count' <<< "$document_type")" -eq 0 ]]; then
              ${pkgs.curl}/bin/curl --fail --silent --show-error --max-time 30 \
                --request DELETE \
                "''${auth[@]}" \
                "$paperless_api/document_types/$unmanaged_document_type_id/" >/dev/null
              echo "Removed unreferenced suggested document type: $type_suggestion"
            fi
          fi

          if [[ "$result" == "failed" ]]; then
            echo "Paperless-AI failed document $document_id; queued for retry" >&2
            exit 1
          fi

          echo "Processed Paperless document $document_id with Paperless-AI"
        '';
      };

      systemd.timers.paperless-ai-reprocess = {
        description = "Dispatch pending Paperless documents to Paperless-AI";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnActiveSec = "1m";
          OnUnitInactiveSec = "1m";
          RandomizedDelaySec = "15s";
          Persistent = true;
        };
      };

      systemd.services.paperless-ai-healthcheck = {
        description = "Paperless-AI application and provider health check";
        after = [ "podman-paperless-ai.service" ];
        wants = [ "podman-paperless-ai.service" ];

        serviceConfig = {
          Type = "oneshot";
          User = "node-exporter";
          Group = "node-exporter";
          LoadCredential = "api_key:${config.sops.secrets."paperless-ai/api_key".path}";
          NoNewPrivileges = true;
          PrivateDevices = true;
          PrivateTmp = true;
          ProtectHome = true;
          ProtectSystem = "strict";
          ReadWritePaths = [ "/var/lib/node_exporter/textfile_collector" ];
        };

        script = ''
          set -uo pipefail

          metrics_dir="/var/lib/node_exporter/textfile_collector"
          metrics_file="$metrics_dir/paperless_ai.prom"
          tmp_file="$metrics_dir/.paperless_ai.prom.tmp"
          endpoint="http://127.0.0.1:${toString listenPort}"
          api_key="$(${pkgs.coreutils}/bin/cat "$CREDENTIALS_DIRECTORY/api_key")"
          app_up=0
          provider_up=0

          if ${pkgs.curl}/bin/curl --fail --silent --max-time 15 "$endpoint/health" >/dev/null 2>&1; then
            app_up=1
          fi

          if status_json="$(${pkgs.curl}/bin/curl --fail --silent --show-error --max-time 30 \
            --header "x-api-key: $api_key" "$endpoint/api/rag/status" 2>/dev/null)"; then
            if ${pkgs.jq}/bin/jq --exit-status '.ai_status == "ok"' <<< "$status_json" >/dev/null; then
              provider_up=1
            fi
          fi

          cat > "$tmp_file" <<EOF
          # HELP paperless_ai_up Paperless-AI application health
          # TYPE paperless_ai_up gauge
          paperless_ai_up $app_up
          # HELP paperless_ai_provider_up Paperless-AI configured provider health
          # TYPE paperless_ai_provider_up gauge
          paperless_ai_provider_up $provider_up
          # HELP paperless_ai_healthcheck_timestamp_seconds Unix timestamp of last health check
          # TYPE paperless_ai_healthcheck_timestamp_seconds gauge
          paperless_ai_healthcheck_timestamp_seconds $(${pkgs.coreutils}/bin/date +%s)
          EOF

          ${pkgs.coreutils}/bin/mv "$tmp_file" "$metrics_file"
        '';
      };

      systemd.timers.paperless-ai-healthcheck = {
        description = "Hourly Paperless-AI provider health check";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnActiveSec = "5m";
          OnUnitActiveSec = "1h";
          RandomizedDelaySec = "5m";
          Persistent = true;
        };
      };

      # ZFS snapshot and replication
      modules.backup.sanoid.datasets.${dataset} =
        forgeDefaults.mkSanoidDataset "paperless-ai";

      modules.alerting.rules = {
        "paperless-ai-service-down" =
          forgeDefaults.mkServiceDownAlert "paperless-ai" "Paperless-AI" "document tagging";

        "paperless-ai-app-unhealthy" = {
          type = "promql";
          alertname = "PaperlessAiAppUnhealthy";
          expr = "paperless_ai_up == 0";
          for = "10m";
          severity = "high";
          labels = { service = "paperless-ai"; category = "availability"; };
          annotations = {
            summary = "Paperless-AI application health check is failing";
            description = "The Paperless-AI /health endpoint is not healthy.";
          };
        };

        "paperless-ai-provider-unhealthy" = {
          type = "promql";
          alertname = "PaperlessAiProviderUnhealthy";
          expr = "paperless_ai_provider_up == 0";
          for = "15m";
          severity = "high";
          labels = { service = "paperless-ai"; category = "dependency"; };
          annotations = {
            summary = "Paperless-AI cannot reach its Anthropic provider";
            description = "The hourly end-to-end provider check failed.";
          };
        };

        "paperless-ai-healthcheck-stale" = {
          type = "promql";
          alertname = "PaperlessAiHealthcheckStale";
          expr = "absent(paperless_ai_healthcheck_timestamp_seconds) or (time() - paperless_ai_healthcheck_timestamp_seconds > 7200)";
          for = "15m";
          severity = "high";
          labels = { service = "paperless-ai"; category = "monitoring"; };
          annotations = {
            summary = "Paperless-AI healthcheck metrics are stale";
            description = "No Paperless-AI healthcheck result has been published for over two hours.";
          };
        };

        "paperless-ai-reprocess-failed" = {
          type = "promql";
          alertname = "PaperlessAiReprocessFailed";
          expr = ''node_systemd_unit_state{name="paperless-ai-reprocess.service",state="failed"} == 1'';
          for = "5m";
          severity = "high";
          labels = { service = "paperless-ai"; category = "processing"; };
          annotations = {
            summary = "Paperless-AI reprocessing bridge failed";
            description = "Documents tagged workflow:reprocess could not be reset and rescanned.";
          };
        };
      };

      # Homepage dashboard contribution
      modules.services.homepage.contributions.paperless-ai = {
        group = "Productivity";
        name = "Paperless AI";
        icon = "paperless-ngx"; # Use paperless icon (no dedicated paperless-ai icon)
        href = "https://${serviceDomain}";
        description = "AI-powered document tagging";
        siteMonitor = "http://127.0.0.1:${toString listenPort}";
      };

      # Gatus black-box monitoring
      modules.services.gatus.contributions.paperless-ai = {
        name = "Paperless-AI";
        group = "Productivity";
        url = "https://${serviceDomain}/";
        interval = "60s";
        conditions = [ "[STATUS] == 200" ];
      };
    })
  ];
}
