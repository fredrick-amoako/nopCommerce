using Nop.Core.Infrastructure;

namespace Nop.Web.Infrastructure;

/// <summary>
/// Registers a lightweight /health endpoint for Docker and load balancer health checks.
/// Runs very early in the pipeline (Order = -1) so it responds even if the app isn't fully initialized.
/// </summary>
public partial class HealthCheckStartup : INopStartup
{
    /// <summary>
    /// Add health check services
    /// </summary>
    public void ConfigureServices(IServiceCollection services, IConfiguration configuration)
    {
        // No services needed for the basic health endpoint
    }

    /// <summary>
    /// Configure the health check endpoint
    /// </summary>
    public void Configure(IApplicationBuilder application)
    {
        application.Map("/health", app =>
        {
            app.Run(async context =>
            {
                context.Response.StatusCode = 200;
                context.Response.ContentType = "application/json";
                await context.Response.WriteAsync("{\"status\":\"healthy\"}");
            });
        });
    }

    /// <summary>
    /// Gets order of this startup configuration implementation.
    /// Set to -1 to run before all other middleware so health checks work even during startup.
    /// </summary>
    public int Order => -1;
}
