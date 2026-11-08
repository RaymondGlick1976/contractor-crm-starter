/**
 * YourCRM - Booking Form Embed Script
 * Usage: <div id="ldg-booking-form"></div>
 *        <script src="https://yoursite.netlify.app/js/booking-embed.js" data-form="your-form-slug"></script>
 */
(function() {
  'use strict';

  // Find the script tag to get configuration
  const currentScript = document.currentScript || (function() {
    const scripts = document.getElementsByTagName('script');
    return scripts[scripts.length - 1];
  })();

  const formSlug = currentScript.getAttribute('data-form') || 'default';
  const containerId = currentScript.getAttribute('data-container') || 'ldg-booking-form';
  const apiBase = currentScript.src.replace('/js/booking-embed.js', '');

  // State
  let formConfig = null;
  let questions = [];
  let uploadedFiles = [];
  let primaryColor = '#3e855f';

  // Wait for DOM to be ready
  function ready(fn) {
    if (document.readyState !== 'loading') {
      fn();
    } else {
      document.addEventListener('DOMContentLoaded', fn);
    }
  }

  // Inject styles
  function injectStyles() {
    if (document.getElementById('ldg-booking-styles')) return;
    
    const style = document.createElement('style');
    style.id = 'ldg-booking-styles';
    style.textContent = `
      .ldg-booking-form * { box-sizing: border-box; margin: 0; padding: 0; }
      .ldg-booking-form { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; background: #ffffff; padding: 24px; border-radius: 8px; }
      .ldg-form-header { text-align: center; margin-bottom: 24px; padding-bottom: 20px; border-bottom: 1px solid #eee; }
      .ldg-form-title { font-size: 1.5rem; font-weight: 600; margin-bottom: 8px; color: var(--ldg-primary, #3e855f); }
      .ldg-form-desc { color: #666; font-size: 0.95rem; }
      .ldg-form-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 16px; }
      .ldg-form-grid-3 { display: grid; grid-template-columns: 1fr 1fr 1fr; gap: 16px; }
      .ldg-form-group { margin-bottom: 16px; }
      .ldg-form-group.full { grid-column: 1 / -1; }
      .ldg-form-label { display: block; font-size: 0.875rem; font-weight: 500; color: #333; margin-bottom: 6px; }
      .ldg-required { color: #e53e3e; }
      .ldg-form-input, .ldg-form-select, .ldg-form-textarea {
        width: 100%; padding: 10px 12px; border: 1px solid #ddd; border-radius: 6px;
        font-size: 0.95rem; transition: border-color 0.2s, box-shadow 0.2s;
        font-family: inherit;
      }
      .ldg-form-input:focus, .ldg-form-select:focus, .ldg-form-textarea:focus {
        outline: none; border-color: var(--ldg-primary, #3e855f);
        box-shadow: 0 0 0 3px rgba(62, 133, 95, 0.1);
      }
      .ldg-form-textarea { min-height: 100px; resize: vertical; }
      .ldg-upload-zone {
        border: 2px dashed #ddd; border-radius: 8px; padding: 30px;
        text-align: center; cursor: pointer; transition: all 0.2s;
      }
      .ldg-upload-zone:hover, .ldg-upload-zone.drag-over {
        border-color: var(--ldg-primary, #3e855f); background: rgba(62, 133, 95, 0.05);
      }
      .ldg-upload-text { color: #999; margin-bottom: 10px; }
      .ldg-upload-btn {
        background: var(--ldg-primary, #3e855f); color: white; border: none;
        padding: 8px 16px; border-radius: 6px; cursor: pointer; font-size: 0.875rem;
      }
      .ldg-upload-preview { display: flex; flex-wrap: wrap; gap: 10px; margin-top: 15px; }
      .ldg-upload-item { position: relative; width: 70px; height: 70px; border-radius: 6px; overflow: hidden; }
      .ldg-upload-item img { width: 100%; height: 100%; object-fit: cover; }
      .ldg-upload-remove {
        position: absolute; top: 2px; right: 2px; background: rgba(0,0,0,0.6);
        color: white; border: none; width: 20px; height: 20px; border-radius: 50%;
        cursor: pointer; font-size: 12px; line-height: 18px;
      }
      .ldg-consent-box { background: #f9fafb; border-radius: 8px; padding: 14px; margin-bottom: 16px; }
      .ldg-consent-text { font-size: 0.75rem; color: #666; line-height: 1.5; }
      .ldg-consent-check { display: flex; align-items: flex-start; gap: 8px; margin-top: 8px; }
      .ldg-consent-check input { margin-top: 3px; }
      .ldg-submit-btn {
        width: 100%; padding: 14px; font-size: 1rem; font-weight: 600;
        color: white; background: var(--ldg-primary, #3e855f); border: none;
        border-radius: 6px; cursor: pointer; transition: all 0.2s;
      }
      .ldg-submit-btn:hover { opacity: 0.9; }
      .ldg-submit-btn:disabled { background: #ccc; cursor: not-allowed; }
      .ldg-loading { text-align: center; padding: 40px; }
      .ldg-spinner {
        width: 36px; height: 36px; border: 3px solid #eee;
        border-top-color: var(--ldg-primary, #3e855f); border-radius: 50%;
        animation: ldg-spin 1s linear infinite; margin: 0 auto 16px;
      }
      @keyframes ldg-spin { to { transform: rotate(360deg); } }
      .ldg-error { color: #e53e3e; background: #fef2f2; padding: 12px; border-radius: 6px; margin-bottom: 16px; }
      .ldg-radio-group label, .ldg-checkbox-label { display: flex; align-items: center; gap: 8px; padding: 6px 0; cursor: pointer; }
      @media (max-width: 600px) {
        .ldg-form-grid, .ldg-form-grid-3 { grid-template-columns: 1fr; }
      }
    `;
    document.head.appendChild(style);
  }

  // Fetch form configuration
  async function fetchFormConfig() {
    try {
      const response = await fetch(`${apiBase}/.netlify/functions/booking-form?slug=${encodeURIComponent(formSlug)}`);
      if (!response.ok) throw new Error('Form not found');
      const data = await response.json();
      formConfig = data.form;
      questions = data.questions || [];
      primaryColor = formConfig.primary_color || '#3e855f';
      return true;
    } catch (err) {
      console.error('Booking Form Error:', err);
      return false;
    }
  }

  // Render the form
  function renderForm(container) {
    container.style.setProperty('--ldg-primary', primaryColor);
    
    let html = `
      <div class="ldg-booking-form">
        <div class="ldg-form-header">
          <h2 class="ldg-form-title">${escapeHtml(formConfig.header_title || 'Request an Appointment')}</h2>
          ${formConfig.header_description ? `<p class="ldg-form-desc">${escapeHtml(formConfig.header_description)}</p>` : ''}
        </div>
        
        <form id="ldg-booking-form-element">
          <input type="hidden" id="ldg-form-id" value="${formConfig.id}">
          
          <!-- Contact Info -->
          <div class="ldg-form-grid">
            <div class="ldg-form-group">
              <label class="ldg-form-label">First Name <span class="ldg-required">*</span></label>
              <input type="text" class="ldg-form-input" id="ldg-first-name" required placeholder="First Name">
            </div>
            <div class="ldg-form-group">
              <label class="ldg-form-label">Last Name <span class="ldg-required">*</span></label>
              <input type="text" class="ldg-form-input" id="ldg-last-name" required placeholder="Last Name">
            </div>
          </div>
          
          <div class="ldg-form-grid">
            <div class="ldg-form-group">
              <label class="ldg-form-label">Email Address <span class="ldg-required">*</span></label>
              <input type="email" class="ldg-form-input" id="ldg-email" required placeholder="Your Email">
            </div>
            <div class="ldg-form-group">
              <label class="ldg-form-label">Phone Number <span class="ldg-required">*</span></label>
              <input type="tel" class="ldg-form-input" id="ldg-phone" required placeholder="Your Phone">
            </div>
          </div>
    `;

    // Address section
    if (formConfig.show_address) {
      html += `
        <div class="ldg-form-group">
          <label class="ldg-form-label">Address <span class="ldg-required">*</span></label>
          <input type="text" class="ldg-form-input" id="ldg-address" required placeholder="Street Address">
        </div>
        <div class="ldg-form-grid-3">
          <div class="ldg-form-group">
            <label class="ldg-form-label">City <span class="ldg-required">*</span></label>
            <input type="text" class="ldg-form-input" id="ldg-city" required placeholder="City">
          </div>
          <div class="ldg-form-group">
            <label class="ldg-form-label">State <span class="ldg-required">*</span></label>
            <input type="text" class="ldg-form-input" id="ldg-state" required placeholder="State">
          </div>
          <div class="ldg-form-group">
            <label class="ldg-form-label">ZIP <span class="ldg-required">*</span></label>
            <input type="text" class="ldg-form-input" id="ldg-zip" required placeholder="ZIP">
          </div>
        </div>
      `;
    }

    // Service Details
    if (formConfig.show_service_details) {
      html += `
        <div class="ldg-form-group">
          <label class="ldg-form-label">Service Details <span class="ldg-required">*</span></label>
          <textarea class="ldg-form-textarea" id="ldg-service-details" required placeholder="Please describe your project..."></textarea>
        </div>
      `;
    }

    // How Heard
    if (formConfig.show_how_heard) {
      html += `
        <div class="ldg-form-group">
          <label class="ldg-form-label">How did you hear about us? <span class="ldg-required">*</span></label>
          <select class="ldg-form-select" id="ldg-how-heard" required>
            <option value="">Select...</option>
            <option value="Google">Google Search</option>
            <option value="Facebook">Facebook</option>
            <option value="Instagram">Instagram</option>
            <option value="Referral">Referral from Friend/Family</option>
            <option value="Houzz">Houzz</option>
            <option value="Home Show">Home Show</option>
            <option value="Other">Other</option>
          </select>
        </div>
      `;
    }

    // Date/Time
    if (formConfig.show_date_time) {
      html += `
        <div class="ldg-form-grid">
          <div class="ldg-form-group">
            <label class="ldg-form-label">Preferred Date</label>
            <input type="date" class="ldg-form-input" id="ldg-preferred-date">
          </div>
          <div class="ldg-form-group">
            <label class="ldg-form-label">Preferred Time</label>
            <input type="time" class="ldg-form-input" id="ldg-preferred-time">
          </div>
        </div>
      `;
    }

    // Custom Questions
    questions.forEach(q => {
      const req = q.is_required ? '<span class="ldg-required">*</span>' : '';
      const reqAttr = q.is_required ? 'required' : '';
      
      if (q.field_type === 'textarea') {
        html += `
          <div class="ldg-form-group">
            <label class="ldg-form-label">${escapeHtml(q.prompt)} ${req}</label>
            <textarea class="ldg-form-textarea" id="ldg-q-${q.id}" ${reqAttr}></textarea>
          </div>
        `;
      } else if (q.field_type === 'dropdown') {
        const opts = (q.choices || []).map(c => `<option value="${escapeHtml(c)}">${escapeHtml(c)}</option>`).join('');
        html += `
          <div class="ldg-form-group">
            <label class="ldg-form-label">${escapeHtml(q.prompt)} ${req}</label>
            <select class="ldg-form-select" id="ldg-q-${q.id}" ${reqAttr}>
              <option value="">Select...</option>
              ${opts}
            </select>
          </div>
        `;
      } else if (q.field_type === 'radio') {
        const opts = (q.choices || []).map((c, i) => 
          `<label><input type="radio" name="ldg-q-${q.id}" value="${escapeHtml(c)}" ${q.is_required && i === 0 ? 'required' : ''}> ${escapeHtml(c)}</label>`
        ).join('');
        html += `
          <div class="ldg-form-group">
            <label class="ldg-form-label">${escapeHtml(q.prompt)} ${req}</label>
            <div class="ldg-radio-group">${opts}</div>
          </div>
        `;
      } else if (q.field_type === 'checkbox') {
        html += `
          <div class="ldg-form-group">
            <label class="ldg-checkbox-label">
              <input type="checkbox" id="ldg-q-${q.id}" ${reqAttr}>
              ${escapeHtml(q.prompt)}
            </label>
          </div>
        `;
      } else {
        html += `
          <div class="ldg-form-group">
            <label class="ldg-form-label">${escapeHtml(q.prompt)} ${req}</label>
            <input type="text" class="ldg-form-input" id="ldg-q-${q.id}" ${reqAttr}>
          </div>
        `;
      }
    });

    // Attachments
    if (formConfig.allow_attachments) {
      const reqLabel = formConfig.attachments_required ? ' <span class="ldg-required">*</span>' : '';
      html += `
        <div class="ldg-form-group">
          <label class="ldg-form-label">Photos of Your Project${reqLabel}</label>
          <div class="ldg-upload-zone" id="ldg-upload-zone">
            <div class="ldg-upload-text">Drag & Drop Images Here</div>
            <div style="color:#999;margin:8px 0;">or</div>
            <button type="button" class="ldg-upload-btn" id="ldg-upload-btn">Browse Files</button>
            <input type="file" id="ldg-file-input" multiple accept="image/*" style="display:none;">
          </div>
          <div class="ldg-upload-preview" id="ldg-upload-preview"></div>
        </div>
      `;
    }

    // SMS Consent
    if (formConfig.show_sms_consent) {
      html += `
        <div class="ldg-consent-box">
          <div class="ldg-consent-check">
            <input type="checkbox" id="ldg-sms-consent">
            <span class="ldg-consent-text">
              I agree to receive text messages from this business. Message frequency varies. 
              Message and data rates may apply. Reply STOP to unsubscribe. Reply HELP for help.
            </span>
          </div>
        </div>
      `;
    }

    html += `
          <button type="submit" class="ldg-submit-btn" id="ldg-submit-btn">Submit Request</button>
        </form>
      </div>
    `;

    container.innerHTML = html;

    // Setup event handlers
    setupEventHandlers(container);
  }

  // Setup event handlers
  function setupEventHandlers(container) {
    // File upload
    if (formConfig.allow_attachments) {
      const uploadZone = container.querySelector('#ldg-upload-zone');
      const fileInput = container.querySelector('#ldg-file-input');
      const uploadBtn = container.querySelector('#ldg-upload-btn');
      const preview = container.querySelector('#ldg-upload-preview');

      uploadBtn.addEventListener('click', () => fileInput.click());
      fileInput.addEventListener('change', (e) => handleFiles(e.target.files, preview));

      uploadZone.addEventListener('dragover', (e) => {
        e.preventDefault();
        uploadZone.classList.add('drag-over');
      });
      uploadZone.addEventListener('dragleave', () => uploadZone.classList.remove('drag-over'));
      uploadZone.addEventListener('drop', (e) => {
        e.preventDefault();
        uploadZone.classList.remove('drag-over');
        handleFiles(e.dataTransfer.files, preview);
      });
    }

    // Form submission
    const form = container.querySelector('#ldg-booking-form-element');
    form.addEventListener('submit', (e) => handleSubmit(e, container));
  }

  // Handle file uploads
  function handleFiles(files, preview) {
    Array.from(files).forEach(file => {
      if (!file.type.startsWith('image/')) return;
      if (uploadedFiles.length >= 10) return;

      const reader = new FileReader();
      reader.onload = (e) => {
        uploadedFiles.push({ file, dataUrl: e.target.result });
        renderPreviews(preview);
      };
      reader.readAsDataURL(file);
    });
  }

  function renderPreviews(preview) {
    preview.innerHTML = uploadedFiles.map((f, i) => `
      <div class="ldg-upload-item">
        <img src="${f.dataUrl}" alt="Upload ${i + 1}">
        <button type="button" class="ldg-upload-remove" data-index="${i}">×</button>
      </div>
    `).join('');

    // Add remove handlers
    preview.querySelectorAll('.ldg-upload-remove').forEach(btn => {
      btn.addEventListener('click', () => {
        const index = parseInt(btn.getAttribute('data-index'));
        uploadedFiles.splice(index, 1);
        renderPreviews(preview);
      });
    });
  }

  // Handle form submission
  async function handleSubmit(e, container) {
    e.preventDefault();

    const submitBtn = container.querySelector('#ldg-submit-btn');
    submitBtn.disabled = true;
    submitBtn.textContent = 'Submitting...';

    // Check for required attachments
    if (formConfig.attachments_required && uploadedFiles.length === 0) {
      alert('Please upload at least one photo.');
      submitBtn.disabled = false;
      submitBtn.textContent = 'Submit Request';
      return;
    }

    // Gather form data
    const formData = {
      form_id: container.querySelector('#ldg-form-id').value,
      first_name: container.querySelector('#ldg-first-name').value,
      last_name: container.querySelector('#ldg-last-name').value,
      email: container.querySelector('#ldg-email').value,
      phone: container.querySelector('#ldg-phone').value,
      address: container.querySelector('#ldg-address')?.value || '',
      city: container.querySelector('#ldg-city')?.value || '',
      state: container.querySelector('#ldg-state')?.value || '',
      zip: container.querySelector('#ldg-zip')?.value || '',
      service_details: container.querySelector('#ldg-service-details')?.value || '',
      how_heard: container.querySelector('#ldg-how-heard')?.value || '',
      preferred_date: container.querySelector('#ldg-preferred-date')?.value || null,
      preferred_time: container.querySelector('#ldg-preferred-time')?.value || null,
      sms_consent: container.querySelector('#ldg-sms-consent')?.checked || false,
      custom_answers: {},
      attachments: []
    };

    // Custom questions
    questions.forEach(q => {
      if (q.field_type === 'radio') {
        const checked = container.querySelector(`input[name="ldg-q-${q.id}"]:checked`);
        formData.custom_answers[q.id] = checked ? checked.value : '';
      } else if (q.field_type === 'checkbox') {
        formData.custom_answers[q.id] = container.querySelector(`#ldg-q-${q.id}`)?.checked || false;
      } else {
        formData.custom_answers[q.id] = container.querySelector(`#ldg-q-${q.id}`)?.value || '';
      }
    });

    // Attachments
    if (uploadedFiles.length > 0) {
      for (const f of uploadedFiles) {
        formData.attachments.push(f.dataUrl);
      }
    }

    try {
      const response = await fetch(`${apiBase}/.netlify/functions/booking-submit`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(formData)
      });

      if (!response.ok) {
        const err = await response.json();
        throw new Error(err.error || 'Submission failed');
      }

      const result = await response.json();

      // Redirect to this business's booking page (or the form's own thank-you URL)
      const scheduleUrl = new URL(result.redirect_url || '/', apiBase);
      window.top.location.href = scheduleUrl.toString();

    } catch (err) {
      console.error('Booking form error:', err);
      alert('There was an error submitting your request. Please try again.');
      submitBtn.disabled = false;
      submitBtn.textContent = 'Submit Request';
    }
  }

  // Utility: escape HTML
  function escapeHtml(text) {
    if (!text) return '';
    const div = document.createElement('div');
    div.textContent = text;
    return div.innerHTML;
  }

  // Initialize
  ready(async function() {
    injectStyles();

    const container = document.getElementById(containerId);
    if (!container) {
      console.error(`Booking Form: Container #${containerId} not found`);
      return;
    }

    // Show loading state
    container.innerHTML = `
      <div class="ldg-booking-form">
        <div class="ldg-loading">
          <div class="ldg-spinner"></div>
          <p>Loading form...</p>
        </div>
      </div>
    `;
    container.style.setProperty('--ldg-primary', primaryColor);

    // Fetch and render
    const success = await fetchFormConfig();
    if (success) {
      renderForm(container);
    } else {
      container.innerHTML = `
        <div class="ldg-booking-form">
          <div class="ldg-error">
            Unable to load the booking form. Please try again later.
          </div>
        </div>
      `;
    }
  });

})();
