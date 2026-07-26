using Microsoft.AspNetCore.Mvc;
using Nop.Core;
using Nop.Core.Domain.Orders;
using Nop.Core.Http.Extensions;
using Nop.Plugin.Payments.Paystack.Models;
using Nop.Services.Catalog;
using Nop.Services.Common;
using Nop.Services.Configuration;
using Nop.Services.Customers;
using Nop.Services.Directory;
using Nop.Services.Localization;
using Nop.Services.Orders;
using Nop.Web.Framework.Components;

namespace Nop.Plugin.Payments.Paystack.Components;

public class PaymentPaystackViewComponent : NopViewComponent
{
    private readonly IWorkContext _workContext;
    private readonly IStoreContext _storeContext;
    private readonly ISettingService _settingService;
    private readonly ILocalizationService _localizationService;
    private readonly IShoppingCartService _shoppingCartService;
    private readonly IOrderTotalCalculationService _orderTotalCalculationService;
    private readonly IAddressService _addressService;
    private readonly ICustomerService _customerService;
    private readonly IPriceFormatter _priceFormatter;
    private readonly ICurrencyService _currencyService;

    public PaymentPaystackViewComponent(
        IWorkContext workContext,
        IStoreContext storeContext,
        ISettingService settingService,
        ILocalizationService localizationService,
        IShoppingCartService shoppingCartService,
        IOrderTotalCalculationService orderTotalCalculationService,
        IAddressService addressService,
        ICustomerService customerService,
        IPriceFormatter priceFormatter,
        ICurrencyService currencyService)
    {
        _workContext = workContext;
        _storeContext = storeContext;
        _settingService = settingService;
        _localizationService = localizationService;
        _shoppingCartService = shoppingCartService;
        _orderTotalCalculationService = orderTotalCalculationService;
        _addressService = addressService;
        _customerService = customerService;
        _priceFormatter = priceFormatter;
        _currencyService = currencyService;
    }

    public async Task<IViewComponentResult> InvokeAsync()
    {
        var customer = await _workContext.GetCurrentCustomerAsync();
        var store = await _storeContext.GetCurrentStoreAsync();
        var settings = await _settingService.LoadSettingAsync<PaystackPaymentSettings>(store.Id);

        var email = (customer?.Email ?? "").Trim();
        if (string.IsNullOrEmpty(email) && customer != null)
        {
            var billingAddress = await _customerService.GetCustomerBillingAddressAsync(customer);
            email = (billingAddress?.Email ?? "").Trim();
        }
        if (string.IsNullOrEmpty(email))
            email = string.Empty;

        var model = new PaymentInfoModel
        {
            Email = email,
            EmailRequired = string.IsNullOrWhiteSpace(email),
            PaymentNote = await _localizationService.GetResourceAsync("Plugins.Payments.Paystack.PaymentNote") ?? "You will be redirected to Paystack to complete the payment.",
            CustomerEmail = string.IsNullOrEmpty(email) ? "N/A" : email,
            OrderTotal = "N/A"
        };

        var cart = await _shoppingCartService.GetShoppingCartAsync(customer, ShoppingCartType.ShoppingCart, store.Id);
        if (cart.Any())
        {
            var (total, _, _, _, _, _) = await _orderTotalCalculationService.GetShoppingCartTotalAsync(cart);
            if (total.HasValue)
            {
                var workingCurrency = await _workContext.GetWorkingCurrencyAsync();
                model.OrderTotal = await _priceFormatter.FormatPriceAsync(total.Value, true, workingCurrency);
            }
        }

        if (Request.IsGetRequest())
            return View("~/Plugins/Payments.Paystack/Views/PaymentInfo.cshtml", model);

        var form = await Request.ReadFormAsync();
        var formEmail = (form["Email"].ToString() ?? "").Trim();
        if (!string.IsNullOrEmpty(formEmail))
            model.Email = formEmail;

        return View("~/Plugins/Payments.Paystack/Views/PaymentInfo.cshtml", model);
    }
}
